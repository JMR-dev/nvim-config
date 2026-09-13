-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
<<<<<<< HEAD
vim.opt.wrap = true
vim.opt.textwidth = 80
=======

-- Pin the Python LSP. This is currently LazyVim's default, but stating it keeps a
-- future LazyVim default change from silently switching to basedpyright.
vim.g.lazyvim_python_lsp = "pyright"
>>>>>>> 340e12d (feat(python): use pyright + ruff, drop the black extra)
