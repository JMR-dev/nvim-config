-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.opt.wrap = true
vim.opt.textwidth = 80

-- Pin the Python LSP. This is currently LazyVim's default, but stating it keeps a
-- future LazyVim default change from silently switching to basedpyright.
vim.g.lazyvim_python_lsp = "pyright"

-- The provider venv lives in Neovim's data dir (~/.local/share/nvim on macOS and
-- Linux, %LOCALAPPDATA%\nvim-data on Windows, renamed by NVIM_APPNAME). The
-- scripts in scripts/ create it.
local venv = vim.fn.stdpath("data") .. "/venv"
vim.g.python3_host_prog = venv .. (vim.fn.has("win32") == 1 and "/Scripts/python.exe" or "/bin/python")
