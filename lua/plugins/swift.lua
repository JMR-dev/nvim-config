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
}
