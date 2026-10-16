-- Format on save only where the project opts in with a .swift-format config.
-- Elsewhere, such as Xcode projects styled by hand or by SwiftLint, a save
-- would restyle the whole file to swift-format's defaults. Manual formatting
-- (<leader>cf) still works.
local file = vim.api.nvim_buf_get_name(0)
if not vim.fs.find(".swift-format", { path = vim.fs.dirname(file), upward = true })[1] then
  vim.b.autoformat = false
end
