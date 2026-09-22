return {
  {
    "vuki656/package-info.nvim",
    event = { "BufReadPre package.json", "BufNewFile package.json" },
    dependencies = { "MunifTanjim/nui.nvim" },
    opts = {},
    keys = {
      {
        "<leader>cpt",
        function()
          require("package-info").toggle()
        end,
        desc = "Toggle package versions",
      },
      {
        "<leader>cps",
        function()
          require("package-info").show()
        end,
        desc = "Show package versions",
      },
      {
        "<leader>cpS",
        function()
          require("package-info").show({ force = true })
        end,
        desc = "Show package versions (force refresh)",
      },
      {
        "<leader>cpc",
        function()
          require("package-info").hide()
        end,
        desc = "Hide package versions",
      },
      {
        "<leader>cpu",
        function()
          require("package-info").update()
        end,
        desc = "Update package on current line",
      },
      {
        "<leader>cpd",
        function()
          require("package-info").delete()
        end,
        desc = "Delete package on current line",
      },
      {
        "<leader>cpi",
        function()
          require("package-info").install()
        end,
        desc = "Install new package",
      },
      {
        "<leader>cpv",
        function()
          require("package-info").change_version()
        end,
        desc = "Change package version",
      },
    },
  },
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>cp", group = "package-info", icon = "󰏗 " },
      },
    },
  },
}
