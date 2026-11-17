return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "swift" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        sourcekit = {
          -- sourcekit-lsp ships with Xcode and the Swift toolchain, not Mason.
          mason = false,
          -- lspconfig also lists C, C++ and Objective-C, which clangd handles.
          filetypes = { "swift" },
        },
      },
    },
  },
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        -- Runs `swift format` from the toolchain; the standalone
        -- swift-format binary isn't on PATH.
        swift = { "swift" },
      },
    },
  },
  {
    "mfussenegger/nvim-lint",
    -- nvim-lint's swiftlint uses the nearest .swiftlint.yml, or SwiftLint's
    -- default rules without one. Its linter is a function, so LazyVim can't
    -- merge a `condition` into it the way it can for table linters. LazyVim
    -- also runs listed linters without checking they're installed, so list it
    -- only where the binary exists (not on Windows or most Linux machines).
    opts = function(_, opts)
      if vim.fn.executable("swiftlint") == 1 then
        opts.linters_by_ft = opts.linters_by_ft or {}
        opts.linters_by_ft.swift = { "swiftlint" }
      end
    end,
  },
}
