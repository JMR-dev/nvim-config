<#
.SYNOPSIS
Sets up this LazyVim config on Windows.

.DESCRIPTION
Installs the tools the config depends on with winget, links or clones the
config into %LOCALAPPDATA%\nvim, and pre-installs plugins, Treesitter parsers
and Mason packages. Safe to re-run. The dependency list is scripts\deps.tsv,
shared with install.sh.

Groups: core node python go dotnet ruby java php beam rust tools swift
(xcode is macOS-only).

.PARAMETER Preset
minimal (core node python), default (adds go dotnet ruby), or full (every
group Windows supports).

.PARAMETER With
Groups to add, e.g. -With java,php

.PARAMETER Without
Groups to remove.

.PARAMETER AppName
Install as NVIM_APPNAME=<name>, beside your current setup.

.PARAMETER Fresh
Also move aside Neovim's data and cache dirs.

.PARAMETER Font
Nerd Font to install (default JetBrainsMono; "none" skips).

.PARAMETER NoWarmup
Skip the headless plugin, parser and Mason install.

.PARAMETER RepoUrl
Repository to clone when run outside a checkout.

.PARAMETER EnableLongPaths
Set git core.longpaths and, from an elevated shell, Windows' LongPathsEnabled.

.PARAMETER DryRun
Show what would happen without changing anything.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\install.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Preset full -Without php

.NOTES
Written for Windows PowerShell 5.1 so it runs on a fresh machine. Keep this
file ASCII: 5.1 reads scripts without a BOM in the ANSI code page.
#>
[CmdletBinding()]
param(
    [ValidateSet('minimal', 'default', 'full')]
    [string]$Preset = 'default',
    [string[]]$With = @(),
    [string[]]$Without = @(),
    [string]$AppName = '',
    [switch]$Fresh,
    [string]$Font = 'JetBrainsMono',
    [switch]$NoWarmup,
    [string]$RepoUrl = 'https://github.com/JMR-dev/nvim-config.git',
    [switch]$EnableLongPaths,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ScriptParams = $PSBoundParameters
$AllGroups = @('core', 'node', 'python', 'go', 'dotnet', 'ruby', 'java', 'php', 'beam', 'rust', 'tools', 'swift', 'xcode')
$NvimMin = '0.11.2'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$TmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('nvim-setup-' + [Guid]::NewGuid().ToString('N'))
$ExtraPath = @((Join-Path $HOME '.cargo\bin'))
$PythonCmd = $null
$RepoDir = $null
$DepsFile = $null
$Selected = @()

$Installed = New-Object System.Collections.Generic.List[string]
$Failed = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]
$Notes = New-Object System.Collections.Generic.List[string]
$Backups = New-Object System.Collections.Generic.List[string]

if (-not $AppName) {
    if ($env:NVIM_APPNAME) { $AppName = $env:NVIM_APPNAME } else { $AppName = 'nvim' }
}

# --- output -------------------------------------------------------------------

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host '  ok     ' -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Detail([string]$Message) {
    Write-Host "         $Message"
}

function Add-Warning([string]$Message) {
    Write-Host '  warn   ' -ForegroundColor Yellow -NoNewline
    Write-Host $Message
    $script:Warnings.Add($Message)
}

function Stop-WithError([string]$Message) {
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

# --- helpers --------------------------------------------------------------------

# Runs a native command with its output on the console and returns the exit
# code. 5.1 turns redirected stderr into terminating errors under 'Stop', so
# relax that here.
function Invoke-Native([string]$Exe, [string[]]$Arguments = @(), [switch]$Quiet) {
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    if ($Quiet) { & $Exe @Arguments *> $null } else { & $Exe @Arguments | Out-Host }
    return $LASTEXITCODE
}

# Runs a native command and returns its output (stdout and stderr) as text.
function Get-NativeOutput([string]$Exe, [string[]]$Arguments = @()) {
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    return ($out -join "`n")
}

# Runs an action, or only describes it under -DryRun.
function Invoke-Step([string]$Description, [scriptblock]$Action) {
    if ($DryRun) {
        Write-Detail "[dry-run] $Description"
        return
    }
    & $Action
}

function Test-Command([string]$Name) {
    return [bool](Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
}

function Get-FirstCommand([string]$Spec) {
    foreach ($name in $Spec.Split('|')) {
        if (Test-Command $name) { return $name }
    }
    return $null
}

function Get-VersionOf([string]$Command) {
    $first = (Get-NativeOutput $Command @('--version')).Split("`n")[0]
    if ($first -match '\d+(\.\d+)*') { return $Matches[0] }
    return $null
}

function Test-VersionAtLeast([string]$Have, [string]$Need) {
    $a = $Have.Split('.')
    $b = $Need.Split('.')
    $n = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0
        $y = 0
        if ($i -lt $a.Count) { [void][int]::TryParse($a[$i], [ref]$x) }
        if ($i -lt $b.Count) { [void][int]::TryParse($b[$i], [ref]$y) }
        if ($x -gt $y) { return $true }
        if ($x -lt $y) { return $false }
    }
    return $true
}

# winget doesn't update the running session's PATH; rebuild it from the registry.
function Update-SessionPath {
    $parts = @($script:ExtraPath)
    $parts += [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';'
    $parts += [Environment]::GetEnvironmentVariable('Path', 'User') -split ';'
    $parts += $env:Path -split ';'
    $env:Path = (@($parts | Where-Object { $_ } | Select-Object -Unique)) -join ';'
}

# Appends a directory to the user PATH, keeping the value REG_EXPAND_SZ (.NET's
# SetEnvironmentVariable would rewrite it as REG_SZ with %VARS% expanded).
function Add-UserPath([string]$Dir) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @($raw -split ';' | Where-Object { $_ })
        if ($entries -contains $Dir) { return }
        $key.SetValue('Path', (($entries + $Dir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    }
    finally {
        $key.Close()
    }
    # Setting and clearing a variable through .NET broadcasts WM_SETTINGCHANGE,
    # so terminals opened from now on see the new PATH.
    [Environment]::SetEnvironmentVariable('NVIM_SETUP_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('NVIM_SETUP_REFRESH', $null, 'User')
    $script:Notes.Add("added $Dir to your user PATH")
    Update-SessionPath
}

function New-TempDir {
    $dir = Join-Path $script:TmpRoot ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# True for anything at Path, including a junction whose target is gone.
function Test-Exists([string]$Path) {
    return [bool](Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
}

# Full path with a junction or symlink at Path resolved to its target.
function Get-RealPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if ($item.LinkType -and $item.Target) {
        return [IO.Path]::GetFullPath(@($item.Target)[0]).TrimEnd('\')
    }
    return $item.FullName.TrimEnd('\')
}

function Split-List([string[]]$Values) {
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# --- custom probes (deps.tsv "@name" in the probe column) -----------------------

# Sets $PythonCmd to the first working Python 3.9+. A fresh Windows has a
# python.exe alias that only points at the Microsoft Store, so run it to check.
function Test-Python {
    $code = 'import sys; sys.exit(sys.version_info < (3, 9))'
    foreach ($exe in @('py', 'python', 'python3')) {
        if (-not (Test-Command $exe)) { continue }
        $pre = @()
        if ($exe -eq 'py') { $pre = @('-3') }
        $null = Get-NativeOutput $exe ($pre + @('-c', $code))
        if ($LASTEXITCODE -eq 0) {
            $script:PythonCmd = @($exe) + $pre
            return $true
        }
    }
    return $false
}

$Probes = @{
    # LazyVim sets CC=gcc itself when it finds gcc on Windows.
    cc     = { [bool]$env:CC -or (Test-Command 'gcc') -or (Test-Command 'cc') -or (Test-Command 'cl') }
    python = { Test-Python }
    pyvenv = { Test-Python }
    dotnet = { (Test-Command 'dotnet') -and ((Get-NativeOutput 'dotnet' @('--list-sdks')) -match '\d') }
    # ruby.lua falls back to ruby-lsp on PATH when there is no rbenv shim.
    ruby   = { (Test-Command 'gem') -and (Test-Command 'ruby-lsp') }
}

# --- installers -------------------------------------------------------------------

function Install-WingetPackage([string]$Id) {
    if ($DryRun) {
        Write-Detail "[dry-run] winget install --exact --id $Id"
        return $true
    }
    $code = Invoke-Native 'winget' @('install', '--exact', '--id', $Id, '--source', 'winget', '--silent',
        '--accept-source-agreements', '--accept-package-agreements')
    Update-SessionPath
    if ($code -eq 0) { return $true }
    # winget fails "install" for packages that are already there.
    return ((Invoke-Native 'winget' @('list', '--exact', '--id', $Id, '--accept-source-agreements') -Quiet) -eq 0)
}

# Mason decompresses .gz downloads (the tree-sitter CLI among them) with 7-Zip,
# which it looks for on PATH. The 7-Zip installer doesn't add itself there.
function Install-SevenZip {
    $dir = Join-Path $env:ProgramFiles '7-Zip'
    $exe = Join-Path $dir '7z.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        if (-not (Install-WingetPackage '7zip.7zip')) { return $false }
    }
    if ($DryRun) {
        Write-Detail "[dry-run] add $dir to your user PATH"
        return $true
    }
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    Add-UserPath $dir
    return $true
}

# RubyInstaller plus ruby-lsp. rbenv doesn't run on Windows, so ruby.lua uses
# ruby-lsp from PATH.
function Install-Ruby {
    if (-not (Test-Command 'gem')) {
        if (-not (Install-WingetPackage 'RubyInstallerTeam.RubyWithDevKit.3.4')) { return $false }
    }
    if ($DryRun) {
        Write-Detail '[dry-run] gem install ruby-lsp'
        return $true
    }
    if (-not (Test-Command 'gem')) { return $false }
    if ((Invoke-Native 'gem' @('install', '--no-document', 'ruby-lsp')) -eq 0) { return $true }
    # ruby-lsp's dependencies have native extensions, built with RubyInstaller's
    # MSYS2 toolchain. Install that and try once more.
    if (Test-Command 'ridk') {
        Write-Detail 'installing the MSYS2 toolchain with ridk, then retrying'
        $null = Invoke-Native 'ridk' @('install', '1', '3')
        return ((Invoke-Native 'gem' @('install', '--no-document', 'ruby-lsp')) -eq 0)
    }
    return $false
}

$Installers = @{
    sevenzip = { Install-SevenZip }
    ruby     = { Install-Ruby }
}

# --- steps ------------------------------------------------------------------------

function Test-Dependency([string]$Probe, [string]$Min) {
    if ($Probe.StartsWith('@')) {
        return [bool](& $Probes[$Probe.Substring(1)])
    }
    $command = Get-FirstCommand $Probe
    if (-not $command) { return $false }
    if ($Min -eq '-') { return $true }
    $version = Get-VersionOf $command
    return [bool]($version -and (Test-VersionAtLeast $version $Min))
}

function Confirm-Dependency([string]$Name, [string]$Probe, [string]$Min, [string]$Spec) {
    $label = $Name
    if ($Min -ne '-') { $label = "$Name >= $Min" }
    if (Test-Dependency $Probe $Min) {
        Write-Ok $label
        return
    }
    if ($Spec -eq '?') {
        Add-Warning "${label}: no winget package; install it yourself"
        $script:Failed.Add($Name)
        return
    }
    Write-Detail "installing $label"
    if ($Spec.StartsWith('@')) {
        $ok = [bool](& $Installers[$Spec.Substring(1)])
    }
    else {
        $ok = Install-WingetPackage $Spec
    }
    if (-not $ok) {
        Add-Warning "${label}: install failed"
        $script:Failed.Add($Name)
        return
    }
    if ($DryRun) { return }
    if (Test-Dependency $Probe $Min) {
        Write-Ok $label
        $script:Installed.Add($Name)
    }
    else {
        Add-Warning "${label}: still missing or too old after installing; open a new terminal and re-run"
        $script:Failed.Add($Name)
    }
}

function Install-Dependencies {
    $rows = Get-Content -LiteralPath $script:DepsFile |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        ConvertFrom-Csv -Delimiter "`t"
    $current = ''
    foreach ($row in $rows) {
        if ($script:Selected -notcontains $row.group) { continue }
        $spec = $row.winget.Trim()
        if ($spec -eq '-') { continue }
        if ($row.group -ne $current) {
            Write-Step "Group: $($row.group)"
            $current = $row.group
        }
        Confirm-Dependency $row.name $row.probe $row.min $spec
    }
}

function Select-Groups {
    switch ($Preset) {
        'minimal' { $groups = @('core', 'node', 'python') }
        'default' { $groups = @('core', 'node', 'python', 'go', 'dotnet', 'ruby') }
        'full' { $groups = @($AllGroups) }
    }
    # @() because PowerShell unrolls a returned one-item array into a string.
    $with = @(Split-List $With)
    $without = @(Split-List $Without)
    foreach ($g in ($with + $without)) {
        if ($AllGroups -notcontains $g) { Stop-WithError "unknown group: $g (groups: $($AllGroups -join ' '))" }
    }
    foreach ($g in $with) {
        if ($groups -notcontains $g) { $groups += $g }
    }
    $groups = @($groups | Where-Object { $without -notcontains $_ })
    if ($groups -contains 'xcode') {
        if ($with -contains 'xcode') { Add-Warning 'the xcode group is macOS-only; skipping it' }
        $groups = @($groups | Where-Object { $_ -ne 'xcode' })
    }
    $script:Selected = $groups
}

function Resolve-Dirs {
    if ($env:XDG_CONFIG_HOME) { $script:ConfigDir = Join-Path $env:XDG_CONFIG_HOME $AppName }
    else { $script:ConfigDir = Join-Path $env:LOCALAPPDATA $AppName }
    # Neovim keeps data and state together in <appname>-data on Windows.
    if ($env:XDG_DATA_HOME) { $script:DataDir = Join-Path $env:XDG_DATA_HOME "$AppName-data" }
    else { $script:DataDir = Join-Path $env:LOCALAPPDATA "$AppName-data" }
    $script:CacheDir = Join-Path ([IO.Path]::GetTempPath()) $AppName
}

# Sets RepoDir when this script runs from a checkout of the config.
function Find-Repo {
    if (-not $PSScriptRoot) { return }
    $candidate = Split-Path -Parent $PSScriptRoot
    if ((Test-Path -LiteralPath (Join-Path $candidate 'lua\config\lazy.lua')) -and
        (Test-Path -LiteralPath (Join-Path $candidate 'scripts\deps.tsv'))) {
        $script:RepoDir = Get-RealPath $candidate
        $script:DepsFile = Join-Path $candidate 'scripts\deps.tsv'
    }
}

function Backup-Item([string]$Path) {
    $dest = "$Path.bak.$Stamp"
    Invoke-Step "move $Path to $dest" { Move-Item -LiteralPath $Path -Destination $dest }
    Write-Detail "moved $Path to $dest"
    $script:Backups.Add($dest)
}

# Run outside a checkout (irm | iex): clone into the config dir and hand over
# to the copy of this script there.
function Invoke-Standalone {
    Write-Step 'Fetching the config'
    if (-not (Test-Command 'git')) {
        if (-not (Install-WingetPackage 'Git.Git')) { Stop-WithError 'git is needed to clone the config' }
    }
    $next = Join-Path $ConfigDir 'scripts\install.ps1'
    if ((Test-Path -LiteralPath $next) -and (Test-Path -LiteralPath (Join-Path $ConfigDir 'scripts\deps.tsv'))) {
        Write-Ok "found a checkout at $ConfigDir"
    }
    else {
        if (Test-Exists $ConfigDir) { Backup-Item $ConfigDir }
        Invoke-Step "git clone $RepoUrl $ConfigDir" {
            if ((Invoke-Native 'git' @('clone', $RepoUrl, $ConfigDir)) -ne 0) { Stop-WithError "git clone $RepoUrl failed" }
        }
    }
    if ($DryRun) {
        Write-Detail "[dry-run] continue with $next"
        exit 0
    }
    if (-not (Test-Path -LiteralPath $next)) { Stop-WithError "$RepoUrl has no scripts\install.ps1; is it the right repository?" }
    # A new process with -ExecutionPolicy Bypass, since the default policy
    # blocks running the cloned file directly.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $next)
    foreach ($key in $ScriptParams.Keys) {
        $value = $ScriptParams[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $argList += "-$key" }
        }
        elseif ($value -is [array]) {
            $argList += "-$key"
            $argList += ($value -join ',')
        }
        else {
            $argList += "-$key"
            $argList += [string]$value
        }
    }
    $shell = (Get-Process -Id $PID).Path
    exit (Invoke-Native $shell $argList)
}

function Set-ConfigLocation {
    Write-Step "Config ($ConfigDir)"
    if ((Get-RealPath $ConfigDir) -eq $RepoDir) {
        Write-Ok 'already in place'
    }
    else {
        if (Test-Exists $ConfigDir) { Backup-Item $ConfigDir }
        # A junction needs neither admin rights nor Developer Mode, unlike a symlink.
        Invoke-Step "create junction $ConfigDir -> $RepoDir" {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ConfigDir) | Out-Null
            New-Item -ItemType Junction -Path $ConfigDir -Target $RepoDir | Out-Null
        }
        Write-Ok "linked to $RepoDir"
    }
    if ($Fresh) {
        foreach ($dir in @($DataDir, $CacheDir)) {
            if (Test-Exists $dir) { Backup-Item $dir }
        }
    }
}

function Install-NerdFont {
    if ($Font -eq 'none') { return }
    Write-Step "Nerd Font ($Font)"
    $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $existing = @(Get-ChildItem -Path $dir -Filter "$($Font)NerdFont*" -ErrorAction SilentlyContinue) +
        @(Get-ChildItem -Path (Join-Path $env:WINDIR 'Fonts') -Filter "$($Font)NerdFont*" -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        Write-Ok "$Font Nerd Font"
        return
    }
    if ($DryRun) {
        Write-Detail "[dry-run] download $Font.zip from the nerd-fonts releases into $dir"
        return
    }
    $tmp = New-TempDir
    $zip = Join-Path $tmp 'font.zip'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$Font.zip" -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'x') -Force
    }
    catch {
        Add-Warning "couldn't download or unpack $Font.zip; check the name against the nerd-fonts releases"
        return
    }
    # Per-user install: copy the files and register them under HKCU.
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $reg = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
    foreach ($file in @(Get-ChildItem -Path (Join-Path $tmp 'x') -Recurse -Include '*.ttf', '*.otf')) {
        $dest = Join-Path $dir $file.Name
        $kind = 'TrueType'
        if ($file.Extension -eq '.otf') { $kind = 'OpenType' }
        try {
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
            New-ItemProperty -Path $reg -Name "$($file.BaseName) ($kind)" -Value $dest -PropertyType String -Force | Out-Null
        }
        catch {
            Add-Warning "couldn't install $($file.Name): $($_.Exception.Message)"
        }
    }
    Write-Ok "$Font Nerd Font"
    $script:Notes.Add("select `"$Font Nerd Font`" in Windows Terminal (Settings > Profiles > Appearance)")
}

function Enable-LongPathSupport {
    if (-not $EnableLongPaths) { return }
    Write-Step 'Long paths'
    if (Test-Command 'git') {
        Invoke-Step 'git config --global core.longpaths true' {
            $null = Invoke-Native 'git' @('config', '--global', 'core.longpaths', 'true')
        }
        Write-Ok 'git core.longpaths'
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Add-Warning 'LongPathsEnabled needs an elevated PowerShell; re-run -EnableLongPaths as administrator to set it'
        return
    }
    Invoke-Step 'set HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled = 1' {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord
    }
    Write-Ok 'Windows LongPathsEnabled'
}

function Initialize-PythonVenv {
    if ($Selected -notcontains 'python') { return }
    Write-Step 'Python provider (pynvim)'
    $venv = Join-Path $DataDir 'venv'
    $python = Join-Path $venv 'Scripts\python.exe'
    if ((Test-Path -LiteralPath $python) -and ((Invoke-Native $python @('-c', 'import pynvim') -Quiet) -eq 0)) {
        Write-Ok $venv
        return
    }
    if (-not (Test-Python)) {
        Add-Warning 'Python 3.9+ is not available; skipped the provider venv'
        return
    }
    if ($DryRun) {
        Write-Detail "[dry-run] $($PythonCmd -join ' ') -m venv $venv; pip install pynvim"
        return
    }
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $exe = $PythonCmd[0]
    $pre = @($PythonCmd | Select-Object -Skip 1)
    $made = (Invoke-Native $exe ($pre + @('-m', 'venv', $venv))) -eq 0
    if ($made -and ((Invoke-Native $python @('-m', 'pip', 'install', '--quiet', '--upgrade', 'pip', 'pynvim')) -eq 0)) {
        Write-Ok $venv
    }
    else {
        Add-Warning "couldn't create the pynvim venv at $venv"
    }
}

function Invoke-HealthCheck {
    $log = Join-Path $TmpRoot 'health.txt'
    $env:NVIM_HEALTH_LOG = $log
    $null = Invoke-Native 'nvim' @('--headless', '+checkhealth lazyvim',
        '+lua vim.fn.writefile(vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.env.NVIM_HEALTH_LOG)', '+qa') -Quiet
    if (-not (Test-Path -LiteralPath $log)) {
        Add-Warning "couldn't run checkhealth lazyvim"
        return
    }
    $errors = @(Select-String -LiteralPath $log -Pattern 'ERROR' -SimpleMatch)
    if ($errors.Count -gt 0) {
        Add-Warning 'checkhealth lazyvim reported errors:'
        foreach ($line in $errors) { Write-Host "           $($line.Line.Trim())" }
    }
    else {
        Write-Ok 'checkhealth lazyvim: no errors'
    }
}

function Invoke-Warmup {
    if ($NoWarmup) {
        Write-Detail 'warm-up skipped (-NoWarmup)'
        return
    }
    Write-Step 'Warm-up: plugins, Treesitter parsers, Mason packages'
    if ($DryRun) {
        Write-Detail '[dry-run] nvim --headless "+Lazy! restore" +qa'
        Write-Detail '[dry-run] nvim --headless (scripts\warmup.lua)'
        Write-Detail '[dry-run] nvim --headless "+checkhealth lazyvim"'
        return
    }
    if (-not (Test-Dependency 'nvim' $NvimMin)) {
        Add-Warning "Neovim >= $NvimMin isn't available; skipped the warm-up"
        return
    }
    $env:NVIM_APPNAME = $AppName
    Write-Detail 'checking out the plugin versions in lazy-lock.json'
    if ((Invoke-Native 'nvim' @('--headless', '+Lazy! restore', '+qa')) -ne 0) { Add-Warning 'Lazy restore failed' }
    Write-Detail 'installing parsers and Mason packages; this takes a few minutes'
    $env:NVIM_WARMUP = Join-Path $ConfigDir 'scripts\warmup.lua'
    if ((Invoke-Native 'nvim' @('--headless', '-c', 'lua dofile(vim.env.NVIM_WARMUP)')) -eq 0) {
        Write-Ok 'warm-up'
    }
    else {
        Add-Warning 'the warm-up reported failures (listed above)'
    }
    Invoke-HealthCheck
}

function Write-Summary {
    Write-Step 'Summary'
    if ($Installed.Count -gt 0) { Write-Host "  installed: $($Installed -join ', ')" }
    if ($Failed.Count -gt 0) {
        Write-Host '  not installed: ' -ForegroundColor Yellow -NoNewline
        Write-Host ($Failed -join ', ')
    }
    if ($Backups.Count -gt 0) {
        Write-Host '  moved aside:'
        foreach ($b in $Backups) { Write-Host "  - $b" }
    }
    # lua/plugins/bazel.lua runs `bazel`; winget's Bazelisk is bazelisk.exe.
    if (($Selected -contains 'tools') -and (Test-Command 'bazelisk') -and -not (Test-Command 'bazel')) {
        $Notes.Add('bazel.lua runs "bazel": copy bazelisk.exe to bazel.exe somewhere on PATH')
    }
    if ($Notes.Count -gt 0) {
        Write-Host ''
        Write-Host '  To finish:'
        foreach ($n in $Notes) { Write-Host "  - $n" }
    }
    if ($Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host '  Warnings:' -ForegroundColor Yellow
        foreach ($w in $Warnings) { Write-Host "  - $w" }
    }
    Write-Host ''
    if ($AppName -eq 'nvim') {
        Write-Host '  Start Neovim with: nvim'
    }
    else {
        Write-Host "  Start Neovim with: `$env:NVIM_APPNAME = '$AppName'; nvim"
    }
}

function Invoke-Main {
    if ($env:OS -ne 'Windows_NT') { Stop-WithError 'this script is for Windows; use scripts/install.sh on macOS and Linux' }
    if (-not (Test-Command 'winget')) {
        Stop-WithError 'winget is missing. Install "App Installer" from the Microsoft Store, then re-run.'
    }
    Select-Groups
    Resolve-Dirs
    Find-Repo
    Update-SessionPath

    Write-Host 'Neovim config setup (windows, winget)'
    Write-Host "  groups:  $($Selected -join ' ')"
    Write-Host "  config:  $ConfigDir"
    if ($DryRun) { Write-Host '  dry run: nothing will be changed' }

    if (-not $RepoDir) { Invoke-Standalone }
    Install-Dependencies
    Enable-LongPathSupport
    Install-NerdFont
    Set-ConfigLocation
    Initialize-PythonVenv
    Invoke-Warmup
    Write-Summary
}

# Environment variables set during the run; restored afterwards in case this
# runs inside an interactive session (irm | iex).
$savedEnv = @{}
foreach ($name in @('NVIM_APPNAME', 'NVIM_WARMUP', 'NVIM_HEALTH_LOG')) {
    $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    New-Item -ItemType Directory -Path $TmpRoot -Force | Out-Null
    Invoke-Main
}
finally {
    foreach ($name in $savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process')
    }
    Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
