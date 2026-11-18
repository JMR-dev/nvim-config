local CONNECTOR_WIDTH = 6 -- "└──── "
local MIN_READABLE_WIDTH = 30
local MIN_WRAP_WIDTH = 10

local SEVERITY_HL = {
  [vim.diagnostic.severity.ERROR] = "DiagnosticVirtualLinesError",
  [vim.diagnostic.severity.WARN] = "DiagnosticVirtualLinesWarn",
  [vim.diagnostic.severity.INFO] = "DiagnosticVirtualLinesInfo",
  [vim.diagnostic.severity.HINT] = "DiagnosticVirtualLinesHint",
}

---@param word string
---@param max_width integer
---@param out string[]
---@return string
local function append_split_word(word, max_width, out)
  local current = ""
  local total_chars = vim.fn.strchars(word)

  for idx = 0, total_chars - 1 do
    local ch = vim.fn.strcharpart(word, idx, 1)
    local candidate = current .. ch
    if vim.fn.strdisplaywidth(candidate) > max_width and current ~= "" then
      table.insert(out, current)
      current = ch
    else
      current = candidate
    end
  end

  return current
end

---@param text string
---@param max_width integer
---@return string[]
local function wrap_text(text, max_width)
  local wrapped = {}

  for raw_line in vim.gsplit(text, "\n", { plain = true }) do
    local current = ""
    for word in raw_line:gmatch("%S+") do
      local candidate = current == "" and word or (current .. " " .. word)
      if vim.fn.strdisplaywidth(candidate) <= max_width then
        current = candidate
      else
        if current ~= "" then
          table.insert(wrapped, current)
        end
        if vim.fn.strdisplaywidth(word) > max_width then
          current = append_split_word(word, max_width, wrapped)
        else
          current = word
        end
      end
    end
    if current ~= "" or #wrapped == 0 then
      table.insert(wrapped, current)
    end
  end

  return wrapped
end

---@param bufnr integer
---@return integer winid
---@return integer max_content
local function window_layout(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 or not vim.api.nvim_win_is_valid(winid) then
    winid = vim.api.nvim_get_current_win()
  end

  local win_info = vim.fn.getwininfo(winid)[1]
  if not win_info then
    return winid, 80
  end

  return winid, math.max(20, win_info.width - win_info.textoff)
end

---@param bufnr integer
---@param lnum integer
---@return integer
local function line_base_indent(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""
  local leading = line:match("^%s*") or ""
  return vim.fn.strdisplaywidth(leading)
end

---@param bufnr integer
---@param diag vim.Diagnostic
---@return integer
local function diag_virt_col(bufnr, diag)
  return vim.api.nvim_buf_call(bufnr, function()
    local end_col = vim.fn.virtcol({ diag.lnum + 1, diag.col + 1 })
    return math.max(0, end_col - 1)
  end)
end

---@param diag vim.Diagnostic
---@param custom_format? fun(diagnostic: vim.Diagnostic): string?
---@return string?
local function format_diag_message(diag, custom_format)
  if custom_format then
    return custom_format(diag)
  end
  if diag.code then
    return string.format("%s: %s", diag.code, diag.message)
  end
  return diag.message
end

---@param bufnr integer
---@param diag vim.Diagnostic
---@param max_content integer
---@param custom_format? fun(diagnostic: vim.Diagnostic): string?
---@param out_lines table[]
local function append_diag_virt_lines(bufnr, diag, max_content, custom_format, out_lines)
  local message = format_diag_message(diag, custom_format)
  if not message or message == "" then
    return
  end

  local hl = SEVERITY_HL[diag.severity] or "DiagnosticVirtualLinesError"
  local diag_col = diag_virt_col(bufnr, diag)
  local max_col_indent = math.max(0, max_content - MIN_READABLE_WIDTH - CONNECTOR_WIDTH)

  local text_indent = diag_col
  if diag_col > max_col_indent then
    -- Pull back to the code line's indent when a right-hand column leaves too little width.
    text_indent = math.min(line_base_indent(bufnr, diag.lnum), max_col_indent)
    if diag_col < max_content and (diag_col - text_indent) >= 2 then
      local elbow = string.rep(" ", text_indent) .. "┌" .. string.rep("─", diag_col - text_indent - 1) .. "┘"
      table.insert(out_lines, { { elbow, hl } })
    end
  end

  local wrap_width = math.max(MIN_WRAP_WIDTH, max_content - text_indent - CONNECTOR_WIDTH)
  local wrapped_lines = wrap_text(message, wrap_width)
  local first_prefix = string.rep(" ", text_indent) .. "└──── "
  local cont_prefix = string.rep(" ", text_indent + CONNECTOR_WIDTH)

  for idx, line_text in ipairs(wrapped_lines) do
    local prefix = idx == 1 and first_prefix or cont_prefix
    table.insert(out_lines, { { prefix, idx == 1 and hl or "" }, { line_text, hl } })
  end
end

---@param virt_ns integer
---@param bufnr integer
---@param diagnostics vim.Diagnostic[]
---@param vl_opts table
local function render_buf_virtual_lines(virt_ns, bufnr, diagnostics, vl_opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, virt_ns, 0, -1)
  if #diagnostics == 0 then
    return
  end

  local winid, max_content = window_layout(bufnr)
  local cursor_lnum = nil
  local visible = diagnostics
  if vl_opts.current_line then
    if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= bufnr then
      return
    end
    cursor_lnum = vim.api.nvim_win_get_cursor(winid)[1] - 1
    visible = vim.tbl_filter(function(d)
      local end_lnum = d.end_lnum or d.lnum
      return cursor_lnum >= d.lnum and cursor_lnum <= end_lnum
    end, diagnostics)
  end

  if #visible == 0 then
    return
  end

  local max_lnum = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1)
  local by_anchor = {}
  for _, diag in ipairs(visible) do
    local anchor = math.min(max_lnum, math.max(0, cursor_lnum or diag.end_lnum or diag.lnum))
    by_anchor[anchor] = by_anchor[anchor] or {}
    table.insert(by_anchor[anchor], diag)
  end

  local custom_format = type(vl_opts.format) == "function" and vl_opts.format or nil
  for anchor_lnum, line_diags in pairs(by_anchor) do
    table.sort(line_diags, function(a, b)
      if a.col ~= b.col then
        return a.col < b.col
      end
      return (a.severity or 0) < (b.severity or 0)
    end)

    local virt_lines = {}
    for _, diag in ipairs(line_diags) do
      append_diag_virt_lines(bufnr, diag, max_content, custom_format, virt_lines)
    end

    if #virt_lines > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, virt_ns, anchor_lnum, 0, {
        virt_lines = virt_lines,
        virt_lines_overflow = "scroll",
      })
    end
  end
end

---@param ns table
---@param bufnr integer
local function clear_buf_autocmds(ns, bufnr)
  if ns.user_data.virt_lines_augroup then
    vim.api.nvim_clear_autocmds({ group = ns.user_data.virt_lines_augroup, buffer = bufnr })
  end
  local resize_ids = ns.user_data.virt_lines_resize_autocmds
  if resize_ids and resize_ids[bufnr] then
    pcall(vim.api.nvim_del_autocmd, resize_ids[bufnr])
    resize_ids[bufnr] = nil
  end
end

local handler_installed = false

local function install_virtual_lines_handler()
  if handler_installed then
    return
  end
  handler_installed = true

  vim.diagnostic.handlers.virtual_lines = {
    show = function(namespace, bufnr, diagnostics, opts)
      bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
      local ns = vim.diagnostic.get_namespace(namespace)

      if not ns.user_data.virt_lines_ns then
        ns.user_data.virt_lines_ns =
          vim.api.nvim_create_namespace(string.format("nvim.%s.diagnostic.virtual_lines", ns.name))
      end
      if not ns.user_data.virt_lines_augroup then
        ns.user_data.virt_lines_augroup =
          vim.api.nvim_create_augroup(string.format("nvim.%s.diagnostic.virt_lines", ns.name), { clear = false })
      end
      ns.user_data.virt_lines_resize_autocmds = ns.user_data.virt_lines_resize_autocmds or {}

      clear_buf_autocmds(ns, bufnr)

      local vl_opts = type(opts and opts.virtual_lines) == "table" and opts.virtual_lines or {}
      local virt_ns = ns.user_data.virt_lines_ns
      local augroup = ns.user_data.virt_lines_augroup

      local function refresh()
        render_buf_virtual_lines(virt_ns, bufnr, diagnostics, vl_opts)
      end

      if vl_opts.current_line then
        vim.api.nvim_create_autocmd({ "CursorMoved", "BufWinEnter" }, {
          group = augroup,
          buffer = bufnr,
          callback = refresh,
        })
      end

      ns.user_data.virt_lines_resize_autocmds[bufnr] = vim.api.nvim_create_autocmd("WinResized", {
        group = augroup,
        pattern = "*",
        callback = function()
          if not vim.api.nvim_buf_is_valid(bufnr) then
            return true
          end
          local winid = vim.fn.bufwinid(bufnr)
          local resized = vim.v.event and vim.v.event.windows
          if winid ~= -1 and (not resized or vim.tbl_contains(resized, winid)) then
            refresh()
          end
        end,
      })

      refresh()
    end,

    hide = function(namespace, bufnr)
      bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
      local ns = vim.diagnostic.get_namespace(namespace)
      clear_buf_autocmds(ns, bufnr)
      if ns.user_data.virt_lines_ns and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns.user_data.virt_lines_ns, 0, -1)
      end
    end,
  }
end

return {
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      install_virtual_lines_handler()
      opts.diagnostics = opts.diagnostics or {}
      opts.diagnostics.virtual_text = false
      opts.diagnostics.virtual_lines = {
        current_line = true,
      }
    end,
  },
}
