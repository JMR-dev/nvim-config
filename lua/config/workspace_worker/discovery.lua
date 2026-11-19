local M = {}

M.MAX_SCAN_DEPTH = 4

local IGNORED_DIRS = {
  [".git"] = true,
  node_modules = true,
  [".venv"] = true,
  venv = true,
  dist = true,
  build = true,
  out = true,
  target = true,
  [".next"] = true,
  [".turbo"] = true,
  __pycache__ = true,
  Pods = true,
  [".build"] = true,
  DerivedData = true,
}

---@param dir string
---@return string
function M.canonical_dir(dir)
  local real = vim.uv.fs_realpath(dir)
  return vim.fs.normalize(real or vim.fn.fnamemodify(dir, ":p"))
end

---@param path string
---@param root string
---@return string
function M.normalize_path(path, root)
  if not vim.startswith(path, "/") then
    path = root .. "/" .. path
  end
  local dir = vim.fs.dirname(path)
  local base = vim.fs.basename(path)
  local real_dir = vim.uv.fs_realpath(dir)
  if real_dir then
    return vim.fs.normalize(real_dir .. "/" .. base)
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

---@param name string
---@param root string
---@param boundary string
---@return string?
local function resolve_local_node_bin(name, root, boundary)
  local cur = M.canonical_dir(root)
  local stop_dir = vim.fs.dirname(M.canonical_dir(boundary))
  while cur and cur ~= "" and cur ~= stop_dir do
    local candidate = cur .. "/node_modules/.bin/" .. name
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
    local parent = vim.fs.dirname(cur)
    if parent == cur then
      break
    end
    cur = parent
  end
  return nil
end

---@param name string
---@param root string
---@param boundary string
---@return string?
local function resolve_local_venv_bin(name, root, boundary)
  local cur = M.canonical_dir(root)
  local stop_dir = vim.fs.dirname(M.canonical_dir(boundary))
  while cur and cur ~= "" and cur ~= stop_dir do
    for _, venv_dir in ipairs({ ".venv", "venv" }) do
      local candidate = cur .. "/" .. venv_dir .. "/bin/" .. name
      if vim.fn.executable(candidate) == 1 then
        return candidate
      end
    end
    local parent = vim.fs.dirname(cur)
    if parent == cur then
      break
    end
    cur = parent
  end
  return nil
end

---@param name string
---@param root string
---@param boundary string
---@param local_only? boolean
---@return string?
function M.resolve_bin(name, root, boundary, local_only)
  local local_bin = resolve_local_node_bin(name, root, boundary)
  if local_bin then
    return local_bin
  end
  if local_only then
    return nil
  end

  local venv_bin = resolve_local_venv_bin(name, root, boundary)
  if venv_bin then
    return venv_bin
  end

  local path_bin = vim.fn.exepath(name)
  if path_bin ~= "" then
    return path_bin
  end

  local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/" .. name
  if vim.fn.executable(mason_bin) == 1 then
    return mason_bin
  end

  return nil
end

---@param markers string[]
---@return table<string, boolean>
local function to_set(markers)
  local set = {}
  for _, m in ipairs(markers) do
    set[m] = true
  end
  return set
end

---@param markers string[]
---@param start_dir string
---@return string?
function M.find_upward_root(markers, start_dir)
  local boundary = vim.fs.root(start_dir, ".git") or start_dir
  local stop_dir = vim.fs.dirname(boundary)
  local found = vim.fs.find(markers, { path = start_dir, upward = true, stop = stop_dir })[1]
  if not found then
    return nil
  end
  return M.canonical_dir(vim.fs.dirname(found))
end

---@param dir string
---@param extensions string[]?
---@param skip_roots table<string, boolean>?
---@param depth? integer
---@return boolean
local function has_matching_source(dir, extensions, skip_roots, depth)
  local cur_depth = depth or 0
  if not extensions or #extensions == 0 or cur_depth > M.MAX_SCAN_DEPTH then
    return false
  end
  if skip_roots and skip_roots[dir] then
    return false
  end

  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return false
  end

  local subdirs = {}
  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if ftype == "file" then
      for _, ext in ipairs(extensions) do
        if vim.endswith(name, ext) then
          return true
        end
      end
    elseif ftype == "directory" and not IGNORED_DIRS[name] then
      table.insert(subdirs, dir .. "/" .. name)
    end
  end

  for _, sub in ipairs(subdirs) do
    if has_matching_source(sub, extensions, skip_roots, cur_depth + 1) then
      return true
    end
  end
  return false
end

---@param path string
---@param roots table<string, boolean>
---@return boolean
local function is_under_any_root(path, roots)
  local cur = path
  while cur and cur ~= "" do
    if roots[cur] then
      return true
    end
    local parent = vim.fs.dirname(cur)
    if parent == cur then
      break
    end
    cur = parent
  end
  return false
end

---@param checker table
---@param workspace_dir string
---@return string[]
function M.find_project_roots(checker, workspace_dir)
  local roots = {}
  local seen = {}
  local function add_root(dir)
    local norm = M.canonical_dir(dir)
    if not seen[norm] then
      seen[norm] = true
      table.insert(roots, norm)
    end
  end

  local upward = M.find_upward_root(checker.markers, workspace_dir)
  if upward then
    add_root(upward)
  end

  local marker_set = to_set(checker.markers)
  local function walk(dir, depth)
    if depth > M.MAX_SCAN_DEPTH then
      return
    end
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      return
    end
    local subdirs = {}
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if marker_set[name] then
        add_root(dir)
      elseif ftype == "directory" and not IGNORED_DIRS[name] then
        table.insert(subdirs, dir .. "/" .. name)
      end
    end
    for _, sub in ipairs(subdirs) do
      walk(sub, depth + 1)
    end
  end

  local base = M.canonical_dir(workspace_dir)
  walk(base, 0)

  -- When a workspace mixes marker-based subprojects and bare source dirs, check uncovered source dirs too.
  if not checker.require_marker and not checker.local_only and not is_under_any_root(base, seen) then
    if #roots == 0 then
      if has_matching_source(base, checker.extensions, seen, 0) then
        add_root(base)
      end
    else
      local handle = vim.uv.fs_scandir(base)
      if handle then
        while true do
          local name, ftype = vim.uv.fs_scandir_next(handle)
          if not name then
            break
          end
          if ftype == "directory" and not IGNORED_DIRS[name] then
            local sub = base .. "/" .. name
            if not is_under_any_root(sub, seen) and has_matching_source(sub, checker.extensions, seen, 1) then
              add_root(sub)
            end
          end
        end
      end
    end
  end

  return roots
end

---@param root string
---@return string[]
function M.resolve_tsc_projects(root)
  local tsconfig = root .. "/tsconfig.json"
  local ok_lines, lines = pcall(vim.fn.readfile, tsconfig)
  if not ok_lines then
    return { tsconfig }
  end
  local text = table.concat(lines, "\n")
  -- Strip line comments and trailing commas gently before attempting JSON decode.
  local stripped = text:gsub("//[^\n]*", ""):gsub(",%s*([}%]])", "%1")
  local ok_json, cfg = pcall(vim.json.decode, stripped)
  if not ok_json or type(cfg) ~= "table" or type(cfg.references) ~= "table" or #cfg.references == 0 then
    return { tsconfig }
  end

  local targets = {}
  if type(cfg.files) ~= "table" or #cfg.files > 0 or type(cfg.include) == "table" then
    table.insert(targets, tsconfig)
  end
  for _, ref in ipairs(cfg.references) do
    local ref_path = type(ref) == "table" and ref.path or nil
    if type(ref_path) == "string" and ref_path ~= "" then
      local abs = M.normalize_path(ref_path, root)
      if vim.fn.isdirectory(abs) == 1 then
        abs = abs .. "/tsconfig.json"
      end
      if vim.fn.filereadable(abs) == 1 then
        table.insert(targets, abs)
      end
    end
  end
  return #targets > 0 and targets or { tsconfig }
end

---@param root string
---@param extensions string[]
---@param max_files? integer
---@return string[]
function M.find_files(root, extensions, max_files)
  local results = {}
  local limit = max_files or 500

  local function walk(dir, depth)
    if #results >= limit or depth > (M.MAX_SCAN_DEPTH + 2) then
      return
    end
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      return
    end
    local subdirs = {}
    while #results < limit do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if ftype == "file" then
        for _, ext in ipairs(extensions) do
          if vim.endswith(name, ext) then
            table.insert(results, dir .. "/" .. name)
            break
          end
        end
      elseif ftype == "directory" and not IGNORED_DIRS[name] then
        table.insert(subdirs, dir .. "/" .. name)
      end
    end
    for _, sub in ipairs(subdirs) do
      if #results >= limit then
        break
      end
      walk(sub, depth + 1)
    end
  end

  walk(M.canonical_dir(root), 0)
  return results
end

return M
