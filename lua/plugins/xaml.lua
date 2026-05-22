return {
  {
    "nvim-treesitter/nvim-treesitter",
    init = function()
      vim.filetype.add({
        extension = {
          xaml = "xaml",
        },
      })
      vim.treesitter.language.register("xml", { "xaml" })
    end,
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      if type(opts.ensure_installed) == "table" and not vim.tbl_contains(opts.ensure_installed, "xml") then
        table.insert(opts.ensure_installed, "xml")
      end
    end,
  },

  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        lemminx = {
          filetypes = { "xml", "xsd", "xsl", "xslt", "svg", "xaml" },
        },
      },
    },
  },

  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      if not vim.tbl_contains(opts.ensure_installed, "lemminx") then
        table.insert(opts.ensure_installed, "lemminx")
      end
    end,
  },
}
