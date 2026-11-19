local CHECKERS = require("config.workspace_worker.checkers")
local discovery = require("config.workspace_worker.discovery")

local M = {}

local DEBOUNCE_MS = 400
local MAX_CONCURRENT = 4

local state = {
  initialized = false,
  namespaces = {},
  tracked_bufs = {},
  root_diags = {},
  lsp_owned_bufs = {},
  active_procs = {},
  pending_queue = {},
  queued_keys = {},
  timers = {},
}

---@param checker_id string
---@return integer
local function get_namespace(checker_id)
  if not state.namespaces[checker_id] then
    state.namespaces[checker_id] = vim.api.nvim_create_namespace("workspace_worker_" .. checker_id)
  end
  return state.namespaces[checker_id]
end

---@param ns integer
---@param bufnr integer
local function reset_if_nonempty(ns, bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) and #vim.diagnostic.get(bufnr, { namespace = ns }) > 0 then
    vim.diagnostic.reset(ns, bufnr)
  end
end

---@param checker table
---@param bufnr integer
local function mark_lsp_owned(checker, bufnr)
  state.lsp_owned_bufs[checker.id] = state.lsp_owned_bufs[checker.id] or {}
  state.lsp_owned_bufs[checker.id][bufnr] = true
end

---@param bufnr integer
---@param checker table
---@return boolean
local function is_buffer_owned(bufnr, checker)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if state.lsp_owned_bufs[checker.id] and state.lsp_owned_bufs[checker.id][bufnr] then
    return true
  end

  if checker.lint_ns and vim.api.nvim_buf_is_loaded(bufnr) then
    local lint_ns = vim.api.nvim_get_namespaces()[checker.lint_ns]
    if lint_ns then
      if #vim.diagnostic.get(bufnr, { namespace = lint_ns }) > 0 then
        return true
      end
      if checker.filetypes[vim.bo[bufnr].filetype] then
        return true
      end
    end
  end

  return false
end

---@param job_key string
local function kill_active_proc(job_key)
  local proc = state.active_procs[job_key]
  if proc then
    pcall(function()
      proc:kill(15)
    end)
    state.active_procs[job_key] = nil
  end
end

---@param checker table
---@param bufnr integer
local function sync_buffer_diagnostics(checker, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = get_namespace(checker.id)
  if is_buffer_owned(bufnr, checker) then
    reset_if_nonempty(ns, bufnr)
    return
  end

  local combined = {}
  local seen = {}
  for _, root_map in pairs(state.root_diags[checker.id] or {}) do
    for _, diag in ipairs(root_map[bufnr] or {}) do
      local key = table.concat({
        tostring(diag.lnum),
        tostring(diag.col),
        tostring(diag.severity),
        tostring(diag.code or ""),
        diag.message or "",
      }, ":")
      if not seen[key] then
        seen[key] = true
        table.insert(combined, diag)
      end
    end
  end

  if #combined > 0 then
    vim.diagnostic.set(ns, bufnr, combined)
  else
    reset_if_nonempty(ns, bufnr)
  end
end

---@param checker table
---@param job_key string
---@param by_file table<string, vim.Diagnostic[]>
local function publish_results(checker, job_key, by_file)
  state.tracked_bufs[checker.id] = state.tracked_bufs[checker.id] or {}
  state.root_diags[checker.id] = state.root_diags[checker.id] or {}

  local prev_tracked = state.tracked_bufs[checker.id][job_key] or {}
  local next_tracked = {}
  local next_root_diags = {}
  local touched_bufs = {}

  for abs_path, diags in pairs(by_file) do
    if #diags > 0 then
      local bufnr = vim.fn.bufadd(abs_path)
      if bufnr and bufnr > 0 then
        next_tracked[bufnr] = true
        next_root_diags[bufnr] = diags
        touched_bufs[bufnr] = true
      end
    end
  end

  state.tracked_bufs[checker.id][job_key] = next_tracked
  state.root_diags[checker.id][job_key] = next_root_diags

  for bufnr in pairs(prev_tracked) do
    if not next_tracked[bufnr] then
      touched_bufs[bufnr] = true
    end
  end

  for bufnr in pairs(touched_bufs) do
    sync_buffer_diagnostics(checker, bufnr)
  end
end

---@return integer
local function active_proc_count()
  local count = 0
  for _ in pairs(state.active_procs) do
    count = count + 1
  end
  return count
end

local start_next_jobs

---@param job table
local function start_job(job)
  local checker = job.checker
  local root = job.root
  local job_key = job.job_key

  kill_active_proc(job_key)

  local cmd = vim.list_extend({ job.bin }, job.args)
  local handle
  handle = vim.system(cmd, { cwd = root, text = true }, function(res)
    vim.schedule(function()
      if state.active_procs[job_key] ~= handle then
        start_next_jobs()
        return
      end
      state.active_procs[job_key] = nil

      local output
      if checker.stream == "stderr" then
        output = (res.stderr and res.stderr ~= "") and res.stderr or res.stdout
      else
        output = (res.stdout and res.stdout ~= "") and res.stdout or res.stderr
      end
      local by_file = checker.parse(output or "", root)
      publish_results(checker, job_key, by_file)
      start_next_jobs()
    end)
  end)

  state.active_procs[job_key] = handle
end

start_next_jobs = function()
  while active_proc_count() < MAX_CONCURRENT and #state.pending_queue > 0 do
    local job = table.remove(state.pending_queue, 1)
    if job then
      state.queued_keys[job.job_key] = nil
      start_job(job)
    end
  end
end

---@param checker table
---@param root string
---@param boundary string
---@param project_file? string
local function enqueue_target(checker, root, boundary, project_file)
  local bin = discovery.resolve_bin(checker.bin, root, boundary, checker.local_only)
  if not bin then
    return
  end

  local args = checker.build_args and checker.build_args(root) or vim.deepcopy(checker.args)
  if not args or #args == 0 then
    return
  end

  local target_root = root
  local job_key = checker.id .. ":" .. root
  if project_file then
    target_root = vim.fs.dirname(project_file)
    args = { "-p", project_file, "--noEmit", "--pretty", "false" }
    job_key = checker.id .. ":" .. project_file
  end

  local job = {
    checker = checker,
    root = target_root,
    bin = bin,
    args = args,
    job_key = job_key,
  }

  if state.queued_keys[job_key] then
    for i, existing in ipairs(state.pending_queue) do
      if existing.job_key == job_key then
        state.pending_queue[i] = job
        return
      end
    end
  end

  state.queued_keys[job_key] = true
  table.insert(state.pending_queue, job)
end

---@param checker table
---@param workspace_dir string
local function run_checker(checker, workspace_dir)
  local boundary = vim.fs.root(workspace_dir, ".git") or workspace_dir
  local roots = discovery.find_project_roots(checker, workspace_dir)
  if #roots == 0 then
    return
  end

  local seen_projects = {}
  for _, root in ipairs(roots) do
    if checker.id == "tsc" then
      for _, project_file in ipairs(discovery.resolve_tsc_projects(root)) do
        if not seen_projects[project_file] then
          seen_projects[project_file] = true
          enqueue_target(checker, root, boundary, project_file)
        end
      end
    else
      enqueue_target(checker, root, boundary)
    end
  end

  start_next_jobs()
end

---@param checker table
---@param start_dir string
local function schedule_checker(checker, start_dir)
  local root = discovery.find_upward_root(checker.markers, start_dir) or start_dir
  local job_key = checker.id .. ":" .. root
  local timer = state.timers[job_key]
  if not timer then
    timer = vim.uv.new_timer()
    state.timers[job_key] = timer
  end

  timer:stop()
  timer:start(DEBOUNCE_MS, 0, function()
    timer:stop()
    vim.schedule(function()
      run_checker(checker, root)
    end)
  end)
end

---@param start_dir? string
function M.run_all(start_dir)
  local dirs = {}
  local seen = {}
  local function add_dir(path)
    if not path or path == "" then
      return
    end
    local norm = discovery.canonical_dir(path)
    if vim.fn.isdirectory(norm) == 1 and not seen[norm] then
      seen[norm] = true
      table.insert(dirs, norm)
    end
  end

  if start_dir then
    add_dir(start_dir)
  else
    add_dir(vim.uv.cwd())
    if vim.fn.argc() > 0 then
      local arg0 = vim.fn.argv(0)
      if type(arg0) == "string" and vim.fn.isdirectory(arg0) == 1 then
        add_dir(arg0)
      end
    end
  end

  for _, dir in ipairs(dirs) do
    for _, checker in ipairs(CHECKERS) do
      run_checker(checker, dir)
    end
  end
end

function M.stop_all()
  state.pending_queue = {}
  state.queued_keys = {}
  for id in pairs(state.active_procs) do
    kill_active_proc(id)
  end
  for id, timer in pairs(state.timers) do
    pcall(function()
      timer:stop()
      timer:close()
    end)
    state.timers[id] = nil
  end
end

---@param ns_id integer
---@return string?
local function get_lsp_client_name(ns_id)
  local info = vim.diagnostic.get_namespace(ns_id)
  local name = info and info.name
  if not name or not vim.startswith(name, "nvim.lsp.") then
    return nil
  end
  return name:match("^nvim%.lsp%.([^%.]+)%.")
end

---@param checker table
---@param bufnr integer
local function clear_buf_worker_diagnostics(checker, bufnr)
  for _, root_bufs in pairs(state.tracked_bufs[checker.id] or {}) do
    root_bufs[bufnr] = nil
  end
  for _, root_map in pairs(state.root_diags[checker.id] or {}) do
    root_map[bufnr] = nil
  end
  reset_if_nonempty(get_namespace(checker.id), bufnr)
end

---@param bufnr integer
---@param diagnostics vim.Diagnostic[]?
local function reconcile_diagnostic_changed(bufnr, diagnostics)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lsp_clients = {}
  for _, diag in ipairs(diagnostics or {}) do
    local client_name = diag.namespace and get_lsp_client_name(diag.namespace)
    if client_name then
      lsp_clients[client_name] = true
    end
  end

  for _, checker in ipairs(CHECKERS) do
    local matched_lsp = false
    for client_name in pairs(lsp_clients) do
      if checker.lsp_clients[client_name] then
        matched_lsp = true
        break
      end
    end

    if matched_lsp then
      mark_lsp_owned(checker, bufnr)
      clear_buf_worker_diagnostics(checker, bufnr)
    elseif checker.lint_ns and is_buffer_owned(bufnr, checker) then
      clear_buf_worker_diagnostics(checker, bufnr)
    end
  end
end

function M.setup()
  if state.initialized then
    return
  end
  state.initialized = true

  local group = vim.api.nvim_create_augroup("WorkspaceDiagnosticWorker", { clear = true })

  -- Mitigation 1: clear worker diagnostics lazily when the attached LSP publishes to ev.buf,
  -- instead of wiping counts on LspAttach before workspace/buffer analysis finishes.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not client or not vim.api.nvim_buf_is_valid(ev.buf) then
        return
      end
      for _, checker in ipairs(CHECKERS) do
        if checker.lsp_clients[client.name] and #vim.lsp.get_clients({ bufnr = ev.buf, name = client.name }) > 0 then
          local has_lsp_diags = false
          for _, diag in ipairs(vim.diagnostic.get(ev.buf)) do
            if diag.namespace and get_lsp_client_name(diag.namespace) == client.name then
              has_lsp_diags = true
              break
            end
          end
          if has_lsp_diags then
            mark_lsp_owned(checker, ev.buf)
            clear_buf_worker_diagnostics(checker, ev.buf)
          end
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not client then
        return
      end
      local client_name = client.name
      local bufnr = ev.buf
      vim.schedule(function()
        for _, checker in ipairs(CHECKERS) do
          if checker.lsp_clients[client_name] and state.lsp_owned_bufs[checker.id] then
            state.lsp_owned_bufs[checker.id][bufnr] = nil
            if #vim.lsp.get_clients({ name = client_name }) == 0 then
              state.lsp_owned_bufs[checker.id] = nil
            end
          end
        end
      end)
    end,
  })

  -- Mitigation 1b: hand over each buffer (including unopened workspace buffers) when an LSP or linter publishes to it.
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function(ev)
      reconcile_diagnostic_changed(ev.buf, ev.data and ev.data.diagnostics)
    end,
  })

  -- Mitigation 3: refresh worker diagnostics for unopened dependent files after saves.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local ft = vim.bo[ev.buf].filetype
      local buf_name = vim.api.nvim_buf_get_name(ev.buf)
      local start_dir = buf_name ~= "" and vim.fs.dirname(buf_name) or vim.uv.cwd()
      if not start_dir then
        return
      end

      for _, checker in ipairs(CHECKERS) do
        if checker.filetypes[ft] then
          schedule_checker(checker, start_dir)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      M.run_all(vim.uv.cwd())
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = M.stop_all,
  })

  vim.api.nvim_create_user_command("WorkspaceDiagnosticsRefresh", function()
    M.run_all()
  end, { desc = "Refresh background workspace diagnostics" })

  vim.api.nvim_create_user_command("WorkspaceDiagnosticsStop", function()
    M.stop_all()
  end, { desc = "Stop background workspace diagnostic workers" })

  M.run_all()
end

return M
