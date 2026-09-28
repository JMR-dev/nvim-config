return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "erlang" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        -- LazyVim's erlang extra still enables erlangls, which is unmaintained
        -- and gone from nvim-lspconfig. ELP replaces it.
        elp = {},
      },
    },
  },
}
