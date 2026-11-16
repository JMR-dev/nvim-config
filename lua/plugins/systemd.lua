return {
  -- Built-in filetype detection only matches unit files under a /systemd/
  -- path and falls back to dosini syntax; this detects unit extensions
  -- anywhere and highlights systemd directives and values.
  {
    "wgwoods/vim-systemd-syntax",
    init = function()
      vim.filetype.add({
        extension = {
          automount = "systemd",
          mount = "systemd",
          path = "systemd",
          scope = "systemd",
          service = "systemd",
          slice = "systemd",
          socket = "systemd",
          swap = "systemd",
          target = "systemd",
          timer = "systemd",
          -- Strip .tmpl so compound names like *.service.tmpl and *.plist.tmpl
          -- resolve to their inner filetype before falling back to systemd.
          tmpl = function(path, bufnr)
            local stripped = path:gsub("%.tmpl$", "")
            if stripped ~= path then
              local ft = vim.filetype.match({
                filename = stripped,
                buf = (bufnr and bufnr > 0) and bufnr or nil,
              })
              if ft then
                return ft
              end
            end
            return "systemd"
          end,
        },
      })
    end,
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        systemd_lsp = {},
      },
    },
  },
}
