local function dap_action(name)
  return function()
    require("xcodebuild.integrations.dap")[name]()
  end
end

local function in_xcode_project()
  local cwd = vim.uv.cwd()
  return vim.fn.glob(cwd .. "/*.xcodeproj") ~= ""
    or vim.fn.glob(cwd .. "/*.xcworkspace") ~= ""
    or vim.uv.fs_stat(cwd .. "/.nvim/xcodebuild") ~= nil
end

return {
  {
    "wojciech-kulik/xcodebuild.nvim",
    -- In an Xcode project, load at startup rather than on first use so the
    -- neo-tree integration syncs the project from the first file operation.
    -- Elsewhere, wait for a key or command so neo-tree stays lazy.
    event = function()
      return in_xcode_project() and { "VeryLazy" } or {}
    end,
    cmd = { "XcodebuildSetup", "XcodebuildPicker", "XcodebuildBuild", "XcodebuildTest" },
    dependencies = {
      "folke/snacks.nvim",
      "MunifTanjim/nui.nvim",
      "nvim-neo-tree/neo-tree.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    opts = {},
    -- The wiki's suggested <leader>x, <leader>b and <leader>d maps collide
    -- with LazyVim's diagnostics, buffer and debug groups.
    keys = {
      { "<leader>XX", "<cmd>XcodebuildPicker<cr>", desc = "All Actions" },
      { "<leader>Xf", "<cmd>XcodebuildProjectManager<cr>", desc = "Project Manager" },
      { "<leader>Xb", "<cmd>XcodebuildBuild<cr>", desc = "Build" },
      { "<leader>XB", "<cmd>XcodebuildBuildForTesting<cr>", desc = "Build for Testing" },
      { "<leader>Xr", "<cmd>XcodebuildBuildRun<cr>", desc = "Build & Run" },
      { "<leader>Xt", "<cmd>XcodebuildTest<cr>", desc = "Run Tests" },
      { "<leader>Xt", "<cmd>XcodebuildTestSelected<cr>", mode = "v", desc = "Run Selected Tests" },
      { "<leader>XT", "<cmd>XcodebuildTestClass<cr>", desc = "Run Test Class" },
      { "<leader>X.", "<cmd>XcodebuildTestRepeat<cr>", desc = "Repeat Last Tests" },
      { "<leader>Xe", "<cmd>XcodebuildTestExplorerToggle<cr>", desc = "Test Explorer" },
      { "<leader>Xl", "<cmd>XcodebuildToggleLogs<cr>", desc = "Toggle Logs" },
      { "<leader>Xc", "<cmd>XcodebuildToggleCodeCoverage<cr>", desc = "Toggle Code Coverage" },
      { "<leader>XC", "<cmd>XcodebuildShowCodeCoverageReport<cr>", desc = "Code Coverage Report" },
      { "<leader>Xs", "<cmd>XcodebuildFailingSnapshots<cr>", desc = "Failing Snapshots" },
      { "<leader>Xp", "<cmd>XcodebuildPreviewGenerateAndShow<cr>", desc = "Generate Preview" },
      { "<leader>XP", "<cmd>XcodebuildPreviewToggle<cr>", desc = "Toggle Preview" },
      { "<leader>Xd", "<cmd>XcodebuildSelectDevice<cr>", desc = "Select Device" },
      { "<leader>Xq", "<cmd>XcodebuildQuickfixLine<cr>", desc = "Quickfix Line" },
      { "<leader>Xa", "<cmd>XcodebuildCodeActions<cr>", desc = "Code Actions" },
      { "<leader>XD", dap_action("build_and_debug"), desc = "Build & Debug" },
      { "<leader>XR", dap_action("debug_without_build"), desc = "Debug Without Building" },
      { "<leader>Xx", dap_action("terminate_session"), desc = "Stop Debugger" },
    },
  },
  {
    -- Registers the iOS debug configuration when nvim-dap first loads, so
    -- the debugger stays lazy like the rest of LazyVim's dap setup.
    "mfussenegger/nvim-dap",
    optional = true,
    opts = function()
      require("xcodebuild.integrations.dap").setup()
    end,
  },
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>X", group = "xcode", icon = " " },
      },
    },
  },
}
