local pulled_clients = {}

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
        if client:supports_method("workspace/diagnostic") then
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
        if package.loaded["lualine"] then
          require("lualine").refresh({ place = { "statusline" } })
        end
      end,
    })

    require("config.workspace_worker").setup()
  end,
})

---@param opts table
local function configure_lualine_workspace_diagnostics(opts)
  local lualine_c = opts.sections and opts.sections.lualine_c
  if type(lualine_c) == "table" then
    for _, component in ipairs(lualine_c) do
      if type(component) == "table" and component[1] == "diagnostics" then
        component.sources = { "nvim_workspace_diagnostic" }
      end
    end
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
