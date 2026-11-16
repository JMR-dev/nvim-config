return {
  -- Strict mode to match the projects' [tool.pyright] settings, so the editor and
  -- `uv run pyright` report the same thing.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        pyright = {
          settings = {
            python = {
              analysis = {
                typeCheckingMode = "strict",
              },
            },
          },
        },
      },
    },
  },

  -- Format with ruff, not black. The formatting.black extra is disabled in
  -- lazyvim.json; this makes the replacement explicit.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        python = { "ruff_fix", "ruff_format" },
      },
    },
  },
}
