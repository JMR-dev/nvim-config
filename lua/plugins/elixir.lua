-- Stands in for LazyVim's elixir extra, whose nvim-lint opts replace
-- linters_by_ft outright and drop every linter configured before it.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    -- A function rather than init: lazy.nvim keeps only the last init for a
    -- plugin, and xaml.lua sets one too.
    opts = function(_, opts)
      vim.treesitter.language.register("markdown", "livebook")
      vim.list_extend(opts.ensure_installed, { "elixir", "heex", "eex" })
    end,
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        expert = {},
      },
    },
  },
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = { elixir = { "credo" } },
      linters = {
        credo = {
          condition = function(ctx)
            return vim.fs.find({ ".credo.exs" }, { path = ctx.filename, upward = true })[1] ~= nil
          end,
        },
      },
    },
  },
}
