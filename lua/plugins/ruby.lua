return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ruby_lsp = {
          -- ruby-lsp must run on the project's Ruby to load its bundle, so use
          -- the rbenv shim rather than Mason's copy, which is tied to whichever
          -- Ruby installed it.
          mason = false,
          cmd = function(dispatchers, config)
            local shim = vim.fn.expand("~/.rbenv/shims/ruby-lsp")
            local exe = vim.fn.executable(shim) == 1 and shim or "ruby-lsp"
            -- rbenv reads .ruby-version from the working directory, and nvim
            -- otherwise starts servers in its own cwd.
            return vim.lsp.rpc.start({ exe }, dispatchers, { cwd = config.root_dir })
          end,
        },
      },
    },
  },
}
