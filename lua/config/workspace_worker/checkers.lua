local discovery = require("config.workspace_worker.discovery")

local PYRIGHT_SEVERITY = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  information = vim.diagnostic.severity.INFO,
}

local ESLINT_SEVERITY = {
  [2] = vim.diagnostic.severity.ERROR,
  [1] = vim.diagnostic.severity.WARN,
}

local SWIFTLINT_SEVERITY = {
  Error = vim.diagnostic.severity.ERROR,
  Warning = vim.diagnostic.severity.WARN,
}

local GOLANGCI_SEVERITY = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  info = vim.diagnostic.severity.INFO,
}

local SHELLCHECK_SEVERITY = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  info = vim.diagnostic.severity.INFO,
  style = vim.diagnostic.severity.HINT,
}

---@param by_file table<string, vim.Diagnostic[]>
---@param file_path string
---@param root string
---@param diag vim.Diagnostic
local function push_diag(by_file, file_path, root, diag)
  local abs_path = discovery.normalize_path(file_path, root)
  by_file[abs_path] = by_file[abs_path] or {}
  table.insert(by_file[abs_path], diag)
end

---@param stdout string
---@return any?
local function decode_json(stdout)
  if not stdout or stdout == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok then
    return nil
  end
  return decoded
end

---@param stdout string
---@param root string
---@return table<string, vim.Diagnostic[]>
local function parse_ruff(stdout, root)
  local items = decode_json(stdout)
  if type(items) ~= "table" then
    return {}
  end

  local by_file = {}
  for _, item in ipairs(items) do
    if type(item) == "table" and item.filename and item.location then
      local lnum = math.max(0, (item.location.row or 1) - 1)
      local col = math.max(0, (item.location.column or 1) - 1)
      local end_loc = item.end_location or item.location
      local end_lnum = math.max(lnum, (end_loc.row or (lnum + 1)) - 1)
      local end_col = math.max(col, (end_loc.column or (col + 1)) - 1)
      local severity = (not item.code or item.code == "invalid-syntax") and vim.diagnostic.severity.ERROR
        or vim.diagnostic.severity.WARN

      push_diag(by_file, item.filename, root, {
        lnum = lnum,
        col = col,
        end_lnum = end_lnum,
        end_col = end_col,
        severity = severity,
        code = item.code,
        source = "ruff",
        message = item.message or "",
      })
    end
  end
  return by_file
end

---@param stdout string
---@param root string
---@return table<string, vim.Diagnostic[]>
local function parse_pyright(stdout, root)
  local data = decode_json(stdout)
  local items = type(data) == "table" and data.generalDiagnostics or nil
  if type(items) ~= "table" then
    return {}
  end

  local by_file = {}
  for _, item in ipairs(items) do
    local range = type(item) == "table" and item.range or nil
    if item.file and range and range.start then
      local finish = range["end"] or range.start
      push_diag(by_file, item.file, root, {
        lnum = math.max(0, range.start.line or 0),
        col = math.max(0, range.start.character or 0),
        end_lnum = math.max(0, finish.line or 0),
        end_col = math.max(0, finish.character or 0),
        severity = PYRIGHT_SEVERITY[item.severity] or vim.diagnostic.severity.ERROR,
        code = item.rule,
        source = "pyright",
        message = item.message or "",
      })
    end
  end
  return by_file
end

---@param stdout string
---@param root string
---@return table<string, vim.Diagnostic[]>
local function parse_eslint(stdout, root)
  local files = decode_json(stdout)
  if type(files) ~= "table" then
    return {}
  end

  local by_file = {}
  for _, entry in ipairs(files) do
    if type(entry) == "table" and entry.filePath and type(entry.messages) == "table" then
      for _, msg in ipairs(entry.messages) do
        local lnum = math.max(0, (msg.line or 1) - 1)
        local col = math.max(0, (msg.column or 1) - 1)
        push_diag(by_file, entry.filePath, root, {
          lnum = lnum,
          col = col,
          end_lnum = math.max(lnum, (msg.endLine or (lnum + 1)) - 1),
          end_col = math.max(col, (msg.endColumn or (col + 1)) - 1),
          severity = ESLINT_SEVERITY[msg.severity] or vim.diagnostic.severity.WARN,
          code = msg.ruleId,
          source = "eslint",
          message = msg.message or "",
        })
      end
    end
  end
  return by_file
end

---@param stdout string
---@param root string
---@return table<string, vim.Diagnostic[]>
local function parse_tsc(stdout, root)
  if not stdout or stdout == "" then
    return {}
  end

  local by_file = {}
  for line in vim.gsplit(stdout, "\n", { plain = true }) do
    local file, lnum_s, col_s, sev_s, code, message = line:match("^(.-)%((%d+),(%d+)%):%s*(%a+)%s*(TS%d+):%s*(.+)$")
    if file and (sev_s == "error" or sev_s == "warning") then
      local lnum = math.max(0, tonumber(lnum_s) - 1)
      local col = math.max(0, tonumber(col_s) - 1)
      push_diag(by_file, file, root, {
        lnum = lnum,
        col = col,
        end_lnum = lnum,
        end_col = col,
        severity = sev_s == "warning" and vim.diagnostic.severity.WARN or vim.diagnostic.severity.ERROR,
        code = code,
        source = "tsc",
        message = message,
      })
    end
  end
  return by_file
end

---@param stdout string
---@param root string
---@return table<string, vim.Diagnostic[]>
local function parse_swiftlint(stdout, root)
  local items = decode_json(stdout)
  if type(items) ~= "table" then
    return {}
  end

  local by_file = {}
  for _, item in ipairs(items) do
    if type(item) == "table" and item.file then
      local lnum = math.max(0, (item.line or 1) - 1)
      local col = math.max(0, (item.character or 1) - 1)
      push_diag(by_file, item.file, root, {
        lnum = lnum,
        col = col,
        end_lnum = lnum,
        end_col = col,
        severity = SWIFTLINT_SEVERITY[item.severity] or vim.diagnostic.severity.WARN,
        code = item.rule_id,
        source = "swiftlint",
        message = item.reason or "",
      })
    end
  end
  return by_file
end

---@param stdout string
---@param root string
---@return table<string, vim.Diagnostic[]>
local function parse_golangci(stdout, root)
  local data = decode_json(stdout)
  local items = type(data) == "table" and data.Issues or nil
  if type(items) ~= "table" then
    return {}
  end

  local by_file = {}
  for _, item in ipairs(items) do
    local pos = type(item) == "table" and item.Pos or nil
    if pos and pos.Filename then
      local lnum = math.max(0, (pos.Line or 1) - 1)
      local col = math.max(0, (pos.Column or 1) - 1)
      push_diag(by_file, pos.Filename, root, {
        lnum = lnum,
        col = col,
        end_lnum = lnum,
        end_col = col,
        severity = GOLANGCI_SEVERITY[item.Severity] or vim.diagnostic.severity.WARN,
        code = item.FromLinter,
        source = "golangci-lint",
        message = item.Text or "",
      })
    end
  end
  return by_file
end

---@param stdout string
---@param root string
---@return table<string, vim.Diagnostic[]>
local function parse_shellcheck(stdout, root)
  local items = decode_json(stdout)
  if type(items) ~= "table" then
    return {}
  end

  local by_file = {}
  for _, item in ipairs(items) do
    if type(item) == "table" and item.file then
      local lnum = math.max(0, (item.line or 1) - 1)
      local col = math.max(0, (item.column or 1) - 1)
      local end_lnum = math.max(lnum, (item.endLine or item.line or 1) - 1)
      local end_col = math.max(col, (item.endColumn or item.column or 1) - 1)
      push_diag(by_file, item.file, root, {
        lnum = lnum,
        col = col,
        end_lnum = end_lnum,
        end_col = end_col,
        severity = SHELLCHECK_SEVERITY[item.level] or vim.diagnostic.severity.WARN,
        code = item.code and ("SC" .. tostring(item.code)) or nil,
        source = "shellcheck",
        message = item.message or "",
      })
    end
  end
  return by_file
end

---@param output string
---@param root string
---@return table<string, vim.Diagnostic[]>
local function parse_markdownlint(output, root)
  if not output or output == "" then
    return {}
  end

  local by_file = {}
  for line in vim.gsplit(output, "\n", { plain = true }) do
    local file, lnum_s, col_s, rest = line:match("^(.-):(%d+):(%d+)%s+(.+)$")
    if not file then
      file, lnum_s, rest = line:match("^(.-):(%d+)%s+(.+)$")
    end
    if file and rest then
      local sev_s, code, msg = rest:match("^(%a+)%s+([%w/-]+)%s+(.+)$")
      if sev_s == "error" or sev_s == "warning" then
        local lnum = math.max(0, tonumber(lnum_s) - 1)
        local col = col_s and math.max(0, tonumber(col_s) - 1) or 0
        push_diag(by_file, file, root, {
          lnum = lnum,
          col = col,
          end_lnum = lnum,
          end_col = col,
          severity = vim.diagnostic.severity.WARN,
          code = code,
          source = "markdownlint",
          message = msg,
        })
      end
    end
  end
  return by_file
end

---@param root string
---@return string[]
local function build_pyright_args(root)
  for _, cfg in ipairs({ "pyrightconfig.json", "pyproject.toml" }) do
    local path = root .. "/" .. cfg
    if vim.fn.filereadable(path) == 1 then
      return { "-p", path, "--outputjson", "." }
    end
  end
  return { "--outputjson", "." }
end

---@param root string
---@return string[]?
local function build_shellcheck_args(root)
  local files = discovery.find_files(root, { ".sh", ".bash" })
  if #files == 0 then
    return nil
  end
  local args = { "-f", "json" }
  vim.list_extend(args, files)
  return args
end

return {
  {
    id = "pyright",
    markers = { "pyrightconfig.json", "pyproject.toml", "setup.py" },
    extensions = { ".py" },
    filetypes = { python = true },
    lsp_clients = { pyright = true, basedpyright = true },
    workspace_lsp = true,
    bin = "pyright",
    args = { "--outputjson", "." },
    build_args = build_pyright_args,
    parse = parse_pyright,
  },
  {
    id = "ruff",
    markers = { "ruff.toml", ".ruff.toml", "pyproject.toml" },
    extensions = { ".py" },
    filetypes = { python = true },
    lsp_clients = { ruff = true, ruff_lsp = true },
    workspace_lsp = false,
    bin = "ruff",
    args = {
      "check",
      "--output-format=json",
      "--no-fix",
      "--quiet",
      "--config",
      'include = ["*.py", "*.pyi", "**/*.py"]',
      ".",
    },
    parse = parse_ruff,
  },
  {
    id = "tsc",
    markers = { "tsconfig.json" },
    require_marker = true,
    filetypes = {
      typescript = true,
      typescriptreact = true,
      javascript = true,
      javascriptreact = true,
    },
    lsp_clients = { vtsls = true, ts_ls = true, tsserver = true },
    workspace_lsp = true,
    local_only = true,
    bin = "tsc",
    args = { "--noEmit", "--pretty", "false" },
    parse = parse_tsc,
  },
  {
    id = "eslint",
    markers = {
      "eslint.config.js",
      "eslint.config.mjs",
      "eslint.config.cjs",
      ".eslintrc",
      ".eslintrc.js",
      ".eslintrc.json",
      ".eslintrc.cjs",
      ".eslintrc.yml",
    },
    require_marker = true,
    filetypes = {
      typescript = true,
      typescriptreact = true,
      javascript = true,
      javascriptreact = true,
      vue = true,
      svelte = true,
      astro = true,
    },
    lsp_clients = { eslint = true },
    workspace_lsp = false,
    local_only = true,
    bin = "eslint",
    args = { "--format", "json", "." },
    parse = parse_eslint,
  },
  {
    id = "swiftlint",
    markers = { ".swiftlint.yml", "Package.swift" },
    extensions = { ".swift" },
    filetypes = { swift = true },
    lsp_clients = {},
    lint_ns = "swiftlint",
    workspace_lsp = false,
    bin = "swiftlint",
    args = { "lint", "--reporter", "json", "--quiet" },
    parse = parse_swiftlint,
  },
  {
    id = "golangci_lint",
    markers = { ".golangci.yml", ".golangci.yaml", "go.mod" },
    require_marker = true,
    filetypes = { go = true },
    lsp_clients = { golangci_lint_ls = true },
    workspace_lsp = false,
    bin = "golangci-lint",
    args = { "run", "--output.json.path=stdout", "--show-stats=false" },
    parse = parse_golangci,
  },
  {
    id = "shellcheck",
    markers = { ".shellcheckrc" },
    extensions = { ".sh", ".bash" },
    filetypes = { sh = true, bash = true },
    lsp_clients = { bashls = true },
    workspace_lsp = false,
    bin = "shellcheck",
    args = { "-f", "json" },
    build_args = build_shellcheck_args,
    parse = parse_shellcheck,
  },
  {
    id = "markdownlint",
    markers = {
      ".markdownlint-cli2.jsonc",
      ".markdownlint-cli2.yaml",
      ".markdownlint.json",
      ".markdownlint.jsonc",
      ".markdownlint.yaml",
    },
    extensions = { ".md", ".markdown" },
    filetypes = { markdown = true, ["markdown.mdx"] = true },
    lsp_clients = {},
    lint_ns = "markdownlint-cli2",
    workspace_lsp = false,
    stream = "stderr",
    bin = "markdownlint-cli2",
    args = {
      "**/*.{md,markdown}",
      "!**/node_modules/**",
      "!**/.git/**",
      "!**/.venv/**",
      "!**/venv/**",
    },
    parse = parse_markdownlint,
  },
}
