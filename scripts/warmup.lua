-- Headless first-run setup shared by install.sh and install.ps1. Run it after
-- `Lazy! restore`, with the config already in place:
--
--   NVIM_WARMUP=/path/to/warmup.lua nvim --headless -c "lua dofile(vim.env.NVIM_WARMUP)"
--
-- It installs the Treesitter parsers and Mason packages that LazyVim would
-- otherwise install on first use, then exits 0, or 1 if anything failed. The
-- package lists come from LazyVim's merged plugin opts, so there is no second
-- list to keep in sync with lua/plugins/.
--
-- NVIM_WARMUP_TIMEOUT sets the per-phase timeout in milliseconds (default 30 min).

local TIMEOUT = tonumber(vim.env.NVIM_WARMUP_TIMEOUT or "") or 30 * 60 * 1000

local failures = {} ---@type string[]

local function log(msg)
  io.stdout:write(msg .. "\n")
  io.stdout:flush()
end

local function fail(what)
  failures[#failures + 1] = what
  log("  FAILED: " .. what)
end

---@param list string[]
---@return string[]
local function dedupe(list)
  local seen, out = {}, {}
  for _, item in ipairs(list) do
    if item and not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  return out
end

local function treesitter()
  log("==> Treesitter parsers")

  -- Installs the tree-sitter CLI with Mason when it isn't on PATH. Its callback
  -- can be skipped when Mason already has the CLI, so wait on the binary too.
  local cli_done, cli_err = false, nil
  LazyVim.treesitter.ensure_treesitter_cli(function(_, err)
    cli_done, cli_err = true, err
  end)
  vim.wait(10 * 60 * 1000, function()
    return cli_done or vim.fn.executable("tree-sitter") == 1
  end, 200)
  if cli_err then
    log("  " .. cli_err)
  end

  local ok, health = LazyVim.treesitter.check()
  if not ok then
    for requirement, present in pairs(health) do
      if not present then
        fail("Treesitter requirement missing: " .. requirement)
      end
    end
    return
  end

  local langs = dedupe(LazyVim.opts("nvim-treesitter").ensure_installed or {})
  local TS = require("nvim-treesitter")
  -- nvim-treesitter skips parsers that are already installed and waits on any
  -- that LazyVim's own config started installing when the plugin loaded.
  local done = false
  TS.install(langs, { summary = true }):await(function()
    done = true
  end)
  if not vim.wait(TIMEOUT, function()
    return done
  end, 500) then
    fail("Treesitter install timed out")
  end

  local installed = {}
  for _, lang in ipairs(TS.get_installed("parsers")) do
    installed[lang] = true
  end
  local missing = 0
  for _, lang in ipairs(langs) do
    if not installed[lang] then
      missing = missing + 1
      fail("parser " .. lang)
    end
  end
  log(("  %d/%d parsers installed"):format(#langs - missing, #langs))
end

--- The Mason packages LazyVim installs: mason.nvim's ensure_installed, plus the
--- LSP servers it would hand to mason-lspconfig. Mirrors the server filter in
--- LazyVim's lsp/init.lua.
---@return string[]
local function wanted_packages()
  local want = {} ---@type string[]
  vim.list_extend(want, LazyVim.opts("mason.nvim").ensure_installed or {})

  local map = require("mason-lspconfig.mappings").get_mason_map().lspconfig_to_package
  local lsp = LazyVim.opts("nvim-lspconfig")
  local setup = lsp.setup or {}
  for server, sopts in pairs(lsp.servers or {}) do
    if server ~= "*" and sopts and map[server] then
      sopts = sopts == true and {} or sopts
      local handler = setup[server] or setup["*"]
      -- A setup handler returning true takes the server over (rustaceanvim,
      -- nvim-jdtls), and LazyVim then leaves it out of the Mason install.
      local taken_over = false
      if handler then
        local ok, ret = pcall(handler, server, sopts)
        taken_over = ok and ret == true
      end
      if sopts.enabled ~= false and sopts.mason ~= false and not taken_over then
        want[#want + 1] = map[server]
      end
    end
  end
  for _, server in ipairs(LazyVim.opts("mason-lspconfig.nvim").ensure_installed or {}) do
    want[#want + 1] = map[server]
  end
  return dedupe(want)
end

local function mason()
  log("==> Mason packages")
  -- Loading the registry loads mason.nvim, whose LazyVim config starts
  -- installing its tools once the registry refreshes. mason-lspconfig skips
  -- ensure_installed in headless mode, so the LSP servers are installed here.
  local mr = require("mason-registry")

  local refreshed = false
  mr.refresh(function()
    refreshed = true
  end)
  if not vim.wait(5 * 60 * 1000, function()
    return refreshed
  end, 200) then
    fail("Mason registry refresh timed out")
    return
  end
  vim.wait(1000) -- let LazyVim's refresh callback start its installs first

  local pkgs = {}
  for _, name in ipairs(wanted_packages()) do
    local ok, pkg = pcall(mr.get_package, name)
    if not ok then
      fail("unknown Mason package " .. name)
    else
      pkgs[#pkgs + 1] = pkg
      if not pkg:is_installed() and not pkg:is_installing() then
        log("  installing " .. name)
        local iok, err = pcall(pkg.install, pkg)
        if not iok then
          log("  " .. tostring(err))
        end
      end
    end
  end

  if not vim.wait(TIMEOUT, function()
    for _, pkg in ipairs(pkgs) do
      if pkg:is_installing() then
        return false
      end
    end
    return true
  end, 1000) then
    fail("Mason installs timed out")
  end

  local missing = 0
  for _, pkg in ipairs(pkgs) do
    if not pkg:is_installed() then
      missing = missing + 1
      fail("mason " .. pkg.name)
    end
  end
  log(("  %d/%d packages installed"):format(#pkgs - missing, #pkgs))
end

if not _G.LazyVim then
  log("LazyVim did not load; is the config in place?")
  vim.cmd("cquit 1")
  return
end

for _, phase in ipairs({ treesitter, mason }) do
  local ok, err = pcall(phase)
  if not ok then
    fail(tostring(err))
  end
end

if #failures > 0 then
  log(("\nWarm-up finished with %d failure(s). Packages that need a runtime you"):format(#failures))
  log("skipped (see --with/--without) are expected to fail here.")
  vim.cmd("cquit 1")
else
  log("\nWarm-up complete.")
  vim.cmd("qa!")
end
