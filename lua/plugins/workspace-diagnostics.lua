local pulled_clients = {}
local lualine_refresh_timer = nil

local PUSH_WORKSPACE_LSP_CLIENTS = {
  pyright = true,
  basedpyright = true,
  vtsls = true,
  omnisharp = true,
}

local function ensure_diagnostic_signs()
  local icons = LazyVim.config.icons.diagnostics
  local signs = vim.diagnostic.config().signs
  if type(signs) == "table" and type(signs.text) == "table" then
    return
  end

  local next_signs = type(signs) == "table" and vim.deepcopy(signs) or {}
  next_signs.text = {
    [vim.diagnostic.severity.ERROR] = icons.Error,
    [vim.diagnostic.severity.WARN] = icons.Warn,
    [vim.diagnostic.severity.HINT] = icons.Hint,
    [vim.diagnostic.severity.INFO] = icons.Info,
  }
  vim.diagnostic.config({ signs = next_signs })

  if package.loaded["neo-tree.events"] and package.loaded["neo-tree.utils"] then
    local events = require("neo-tree.events")
    local utils = require("neo-tree.utils")
    events.fire_event(events.VIM_DIAGNOSTIC_CHANGED, { diagnostics_lookup = utils.get_diagnostic_counts() })
  end
end

vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  once = true,
  callback = function()
    -- Apply diagnostic sign icons before background workers emit diagnostics so neo-tree never falls back to "E".
    ensure_diagnostic_signs()

    local group = vim.api.nvim_create_augroup("WorkspaceLspPullDiagnostics", { clear = true })
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      callback = function(ev)
        local client = vim.lsp.get_client_by_id(ev.data.client_id)
        if not client or pulled_clients[client.id] then
          return
        end
        if not PUSH_WORKSPACE_LSP_CLIENTS[client.name] and client:supports_method("workspace/diagnostic") then
          pulled_clients[client.id] = true
          vim.lsp.buf.workspace_diagnostics({ client_id = client.id })
        end
      end,
    })

    vim.api.nvim_create_autocmd("LspDetach", {
      group = group,
      callback = function(ev)
        local client = vim.lsp.get_client_by_id(ev.data.client_id)
        if not client or vim.tbl_isempty(client.attached_buffers or {}) then
          pulled_clients[ev.data.client_id] = nil
        end
      end,
    })

    vim.api.nvim_create_autocmd("DiagnosticChanged", {
      group = group,
      callback = function()
        if not package.loaded["lualine"] then
          return
        end
        if not lualine_refresh_timer then
          lualine_refresh_timer = vim.uv.new_timer()
        end
        lualine_refresh_timer:stop()
        lualine_refresh_timer:start(120, 0, function()
          vim.schedule(function()
            if package.loaded["lualine"] then
              require("lualine").refresh({ place = { "statusline" } })
            end
          end)
        end)
      end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        if lualine_refresh_timer then
          lualine_refresh_timer:stop()
          lualine_refresh_timer:close()
          lualine_refresh_timer = nil
        end
      end,
    })

    require("config.workspace_worker").setup()
  end,
})

---@param opts table
local function configure_lualine_workspace_diagnostics(opts)
  opts.sections = opts.sections or {}
  local lualine_b = type(opts.sections.lualine_b) == "table" and opts.sections.lualine_b or {}
  local lualine_c = opts.sections.lualine_c
  if type(lualine_c) == "table" then
    local kept_c = {}
    for _, component in ipairs(lualine_c) do
      if type(component) == "table" and component[1] == "diagnostics" then
        component.sources = { "nvim_workspace_diagnostic" }
        table.insert(lualine_b, component)
      else
        table.insert(kept_c, component)
      end
    end
    opts.sections.lualine_c = kept_c
    opts.sections.lualine_b = lualine_b
  end

  -- Keep the main statusline (with workspace diagnostic counts) visible while browsing inside neo-tree.
  if type(opts.extensions) == "table" then
    opts.extensions = vim.tbl_filter(function(ext)
      return ext ~= "neo-tree"
    end, opts.extensions)
  end
end

---@param node any
local function enable_warning_indicators(node)
  if type(node) ~= "table" then
    return
  end
  if node[1] == "diagnostics" then
    node.errors_only = false
    return
  end
  for _, child in ipairs(node) do
    enable_warning_indicators(child)
  end
  if type(node.content) == "table" then
    enable_warning_indicators(node.content)
  end
end

local PRIMARY_DIAGNOSTIC_SEVERITIES = {
  { key = "error", icon_key = "Error", sev = vim.diagnostic.severity.ERROR, hl = "DiagnosticSignError" },
  { key = "warn", icon_key = "Warn", sev = vim.diagnostic.severity.WARN, hl = "DiagnosticSignWarn" },
}

local FALLBACK_DIAGNOSTIC_SEVERITIES = {
  { key = "info", icon_key = "Info", sev = vim.diagnostic.severity.INFO, hl = "DiagnosticSignInfo" },
  { key = "hint", icon_key = "Hint", sev = vim.diagnostic.severity.HINT, hl = "DiagnosticSignHint" },
}

---@param path string
---@return string
local function normalize_tree_path(path)
  local normalized = vim.fs.normalize(path)
  if #normalized > 1 and normalized:sub(-1) == "/" then
    return normalized:sub(1, -2)
  end
  return normalized
end

---@param counts table<integer, integer>
---@param found table<integer, boolean>
local function record_diagnostic_counts(counts, found)
  for sev, count in pairs(counts) do
    if count > 0 then
      found[sev] = true
    end
  end
end

---@param node table
---@return table<integer, boolean>
local function collect_node_severities(node)
  local found = {}
  local node_id = node:get_id()
  if type(node_id) ~= "string" or node_id == "" then
    return found
  end

  if node.type == "directory" then
    local dir_path = normalize_tree_path(node_id)
    local dir_prefix = dir_path == "/" and "/" or (dir_path .. "/")
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= "" and normalize_tree_path(name):sub(1, #dir_prefix) == dir_prefix then
          record_diagnostic_counts(vim.diagnostic.count(bufnr), found)
          if found[vim.diagnostic.severity.ERROR] and found[vim.diagnostic.severity.WARN] then
            return found
          end
        end
      end
    end
    return found
  end

  local bufnr = vim.fn.bufnr(node_id)
  if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
    record_diagnostic_counts(vim.diagnostic.count(bufnr), found)
  end
  return found
end

---@param config table
---@param item table
---@param icons table
---@return string?
local function resolve_diagnostic_symbol(config, item, icons)
  local sym = config.symbols and config.symbols[item.key] or icons[item.icon_key]
  if type(sym) ~= "string" or sym == "" then
    return nil
  end
  return sym:sub(-1) == " " and sym or (sym .. " ")
end

---@param config table
---@param node table
---@return table[]
local function render_multi_diagnostics(config, node)
  if node.type == "directory" and config.hide_when_expanded and node:is_expanded() then
    return {}
  end

  local found = collect_node_severities(node)
  if vim.tbl_isempty(found) then
    return {}
  end

  local icons = LazyVim.config.icons.diagnostics
  local spans = {}
  for _, item in ipairs(PRIMARY_DIAGNOSTIC_SEVERITIES) do
    local allow = not config.errors_only or item.sev == vim.diagnostic.severity.ERROR
    if allow and found[item.sev] then
      local sym = resolve_diagnostic_symbol(config, item, icons)
      if sym then
        table.insert(spans, { text = sym, highlight = item.hl, no_padding = #spans > 0 })
      end
    end
  end

  if #spans == 0 and not config.errors_only then
    for _, item in ipairs(FALLBACK_DIAGNOSTIC_SEVERITIES) do
      if found[item.sev] then
        local sym = resolve_diagnostic_symbol(config, item, icons)
        if sym then
          table.insert(spans, { text = sym, highlight = item.hl })
          break
        end
      end
    end
  end

  return spans
end

---@param opts table
local function configure_neotree_diagnostics(opts)
  ensure_diagnostic_signs()

  local icons = LazyVim.config.icons.diagnostics
  opts.default_component_configs = opts.default_component_configs or {}
  opts.default_component_configs.diagnostics =
    vim.tbl_deep_extend("force", opts.default_component_configs.diagnostics or {}, {
      symbols = {
        error = icons.Error,
        warn = icons.Warn,
        info = icons.Info,
        hint = icons.Hint,
      },
    })

  for _, source_name in ipairs({ "filesystem", "buffers", "git_status" }) do
    opts[source_name] = opts[source_name] or {}
    opts[source_name].components = opts[source_name].components or {}
    opts[source_name].components.diagnostics = render_multi_diagnostics
  end

  opts.renderers = opts.renderers or {}
  if not opts.renderers.directory then
    local ok, defaults = pcall(require, "neo-tree.defaults")
    if ok and defaults.renderers and defaults.renderers.directory then
      opts.renderers.directory = vim.deepcopy(defaults.renderers.directory)
    end
  end
  enable_warning_indicators(opts.renderers.directory)

  -- Seed initial diagnostic lookup if neo-tree opens after background workers already published diagnostics.
  local ok_events, events = pcall(require, "neo-tree.events")
  if ok_events then
    opts.event_handlers = opts.event_handlers or {}
    table.insert(opts.event_handlers, {
      event = events.BEFORE_RENDER,
      handler = function(tree_state)
        if tree_state.name == "filesystem" and tree_state.diagnostics_lookup == nil then
          tree_state.diagnostics_lookup = require("neo-tree.utils").get_diagnostic_counts()
        end
      end,
    })
  end
end

return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        vtsls = {
          settings = {
            typescript = {
              tsserver = {
                experimental = {
                  enableProjectDiagnostics = true,
                },
              },
            },
          },
        },
        omnisharp = {
          settings = {
            dotnet = {
              backgroundAnalysis = {
                analyzerDiagnosticsScope = "fullSolution",
                compilerDiagnosticsScope = "fullSolution",
              },
            },
          },
        },
      },
    },
  },
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = function(_, opts)
      configure_neotree_diagnostics(opts)
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      configure_lualine_workspace_diagnostics(opts)
    end,
  },
}
