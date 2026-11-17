#!/usr/bin/env bash
# Set up this LazyVim config on macOS or Linux: install the tools it depends on,
# put the config where Neovim looks for it, and pre-install plugins, Treesitter
# parsers and Mason packages. Safe to re-run. See README.md or --help.
#
# The dependency list lives in scripts/deps.tsv, shared with install.ps1.
#
# Written for bash 3.2, the /bin/bash on macOS: no associative arrays, mapfile,
# ${var,,}, or expanding an empty array under `set -u`. Installer functions run
# in `if` conditions, where `set -e` is off, so they check each step themselves.

set -eu

REPO_URL_DEFAULT="https://github.com/JMR-dev/nvim-config.git"
ALL_GROUPS="core node python go dotnet ruby java php beam rust tools swift xcode"
NVIM_MIN="0.11.2"
TAB=$(printf '\t')
CR=$(printf '\r')

PRESET=default
WITH=""
WITHOUT=""
APPNAME="${NVIM_APPNAME:-nvim}"
FRESH=0
FONT="JetBrainsMono"
WARMUP=1
REPO_URL="$REPO_URL_DEFAULT"
ALLOW_ROOT=0
DRY_RUN=0

INSTALLED=""
FAILED=""
WARNINGS=""
NOTES=""
BACKUPS=""
BIN_TOUCHED=0
APT_UPDATED=0
REPO_DIR=""
DEPS_FILE=""
TMP_ROOT=""

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Installs the tools this Neovim config needs, links or clones the config into
place, and pre-installs plugins, Treesitter parsers and Mason packages.

Options:
  --preset NAME   minimal | default | full            (default: default)
                    minimal  core node python
                    default  core node python go dotnet ruby
                    full     every group this OS supports
  --with LIST     add groups, comma-separated (e.g. java,php)
  --without LIST  remove groups, comma-separated
  --appname NAME  install as NVIM_APPNAME=NAME, beside your current setup
  --fresh         also move aside Neovim's data, state and cache dirs
  --font NAME     Nerd Font to install (default JetBrainsMono; "none" skips)
  --no-warmup     skip the headless plugin, parser and Mason install
  --repo URL      repository to clone when run outside a checkout
  --allow-root    allow running as root (containers)
  --dry-run       show what would happen without changing anything
  -h, --help      show this help

Groups: core node python go dotnet ruby java php beam rust tools swift xcode
EOF
}

# --- output -----------------------------------------------------------------

if [ -t 1 ]; then
  BOLD=$(printf '\033[1m') GREEN=$(printf '\033[32m') YELLOW=$(printf '\033[33m')
  RED=$(printf '\033[31m') RESET=$(printf '\033[0m')
else
  BOLD="" GREEN="" YELLOW="" RED="" RESET=""
fi

step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok() { printf '  %sok%s     %s\n' "$GREEN" "$RESET" "$*"; }
info() { printf '         %s\n' "$*"; }
warn() {
  printf '  %swarn%s   %s\n' "$YELLOW" "$RESET" "$*" >&2
  WARNINGS="$WARNINGS
  - $*"
}
note() {
  NOTES="$NOTES
  - $*"
}
die() {
  printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

# --- helpers ----------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Run a command, or only print it under --dry-run.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '         [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

as_root() {
  if [ -n "$SUDO" ]; then run "$SUDO" "$@"; else run "$@"; fi
}

mktemp_dir() { mktemp -d "$TMP_ROOT/dl.XXXXXX"; }

download() { curl -fsSL --retry 3 -o "$2" "$1"; }

sha256() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# verify_sha256 FILE SUMS_URL NAME: check FILE against NAME's line in a
# "<hash>  <name>" checksum file. Missing checksums warn; a mismatch fails.
verify_sha256() {
  local sums="$1.sums" expected
  if ! download "$2" "$sums" 2>/dev/null; then
    warn "no checksum file at $2; $3 not verified"
    return 0
  fi
  expected=$(awk -v f="$3" '$2 == f || $2 == "*" f { print $1; exit }' "$sums")
  if [ -z "$expected" ]; then
    warn "no checksum for $3 in $2; not verified"
    return 0
  fi
  if [ "$expected" != "$(sha256 "$1")" ]; then
    warn "checksum mismatch for $3"
    return 1
  fi
}

# Prints the first command in "a|b|c" that exists.
first_cmd() {
  local IFS='|' c
  for c in $1; do
    if have "$c"; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

version_of() { "$1" --version 2>&1 | head -n 1 | grep -Eo '[0-9]+(\.[0-9]+)*' | head -n 1; }

# version_ge A B: true when dotted version A >= B.
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); if (m > n) n = m
    for (i = 1; i <= n; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 0 }'
}

in_groups() {
  case " $SELECTED " in *" $1 "*) return 0 ;; esac
  return 1
}

path_note() {
  case ":$ORIG_PATH:" in
    *":$1:"*) ;;
    *) note "add $1 to PATH in your shell profile" ;;
  esac
}

# --- setup ------------------------------------------------------------------

set_opt() {
  case "$1" in
    --preset) PRESET=$2 ;;
    --with) WITH="$WITH,$2" ;;
    --without) WITHOUT="$WITHOUT,$2" ;;
    --appname) APPNAME=$2 ;;
    --font) FONT=$2 ;;
    --repo) REPO_URL=$2 ;;
  esac
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --preset | --with | --without | --appname | --font | --repo)
        [ $# -ge 2 ] || die "$1 needs a value"
        set_opt "$1" "$2"
        shift 2
        ;;
      --preset=* | --with=* | --without=* | --appname=* | --font=* | --repo=*)
        set_opt "${1%%=*}" "${1#*=}"
        shift
        ;;
      --fresh) FRESH=1 && shift ;;
      --no-warmup) WARMUP=0 && shift ;;
      --allow-root) ALLOW_ROOT=1 && shift ;;
      --dry-run) DRY_RUN=1 && shift ;;
      -h | --help) usage && exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
}

detect_platform() {
  ARCH=$(uname -m)
  case "$(uname -s)" in
    Darwin)
      PLATFORM=mac
      PM=brew
      ;;
    Linux)
      PLATFORM=linux
      if have apt-get; then
        PM=apt
      elif have dnf; then
        PM=dnf
      elif have pacman; then
        PM=pacman
      else
        die "no supported package manager (apt, dnf or pacman)"
      fi
      ;;
    *) die "unsupported OS $(uname -s); on Windows use scripts/install.ps1" ;;
  esac
}

check_user() {
  SUDO=""
  if [ "$(id -u)" = 0 ]; then
    [ "$PLATFORM" = linux ] || die "Homebrew won't run as root; run this as your normal user"
    [ "$ALLOW_ROOT" = 1 ] || die "don't run this as root: it installs into your home directory and uses sudo when needed (--allow-root for containers)"
  elif [ "$PLATFORM" = linux ]; then
    have sudo || die "sudo is needed to install packages"
    SUDO=sudo
  fi
}

load_brew_env() {
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$b" ]; then
      eval "$("$b" shellenv)"
      return 0
    fi
  done
  return 1
}

setup_path() {
  ORIG_PATH=$PATH
  LOCAL_BIN="$HOME/.local/bin"
  OPT_DIR="$HOME/.local/opt"
  PATH="$LOCAL_BIN:$HOME/.cargo/bin:$HOME/.rbenv/bin:$HOME/.rbenv/shims:$HOME/.dotnet:$PATH"
  if [ "$PLATFORM" = mac ]; then load_brew_env || true; fi
  export PATH
}

valid_group() {
  case " $ALL_GROUPS " in
    *" $1 "*) ;;
    *) die "unknown group: $1 (groups: $ALL_GROUPS)" ;;
  esac
}

remove_group() { SELECTED=$(echo " $SELECTED " | sed "s/ $1 / /g"); }

select_groups() {
  case "$PRESET" in
    minimal) SELECTED="core node python" ;;
    default) SELECTED="core node python go dotnet ruby" ;;
    full) SELECTED="$ALL_GROUPS" ;;
    *) die "unknown preset: $PRESET (minimal, default, full)" ;;
  esac
  local g
  for g in $(echo "$WITH" | tr ',' ' '); do
    valid_group "$g"
    in_groups "$g" || SELECTED="$SELECTED $g"
  done
  for g in $(echo "$WITHOUT" | tr ',' ' '); do
    valid_group "$g"
    remove_group "$g"
  done
  if [ "$PLATFORM" != mac ] && in_groups xcode; then
    case ",$WITH," in *,xcode,*) warn "the xcode group is macOS-only; skipping it" ;; esac
    remove_group xcode
  fi
  local normalized="" # collapse the spaces left by removals
  for g in $SELECTED; do normalized="$normalized $g"; done
  SELECTED=${normalized# }
}

resolve_dirs() {
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APPNAME"
  DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APPNAME"
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$APPNAME"
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/$APPNAME"
}

# Sets REPO_DIR when this script runs from a checkout of the config.
locate_repo() {
  local src="${BASH_SOURCE[0]:-}" dir
  if [ -z "$src" ] || [ ! -f "$src" ]; then return 0; fi
  dir=$(cd -P "$(dirname "$src")/.." && pwd) || return 0
  if [ -f "$dir/lua/config/lazy.lua" ] && [ -f "$dir/scripts/deps.tsv" ]; then
    REPO_DIR=$dir
    DEPS_FILE="$dir/scripts/deps.tsv"
  fi
}

# --- package managers ---------------------------------------------------------

ensure_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    ok "Xcode Command Line Tools"
    return 0
  fi
  info "installing the Xcode Command Line Tools; finish the dialog that opens"
  run xcode-select --install || true
  [ "$DRY_RUN" = 1 ] && return 0
  until xcode-select -p >/dev/null 2>&1; do sleep 5; done
  ok "Xcode Command Line Tools"
}

bootstrap() {
  step "Package manager ($PM)"
  if [ "$PM" != brew ]; then
    ok "$PM"
    return 0
  fi
  # The CLT provide git, a C compiler and swift; /usr/bin has stubs for them
  # that exist even without the CLT, so make sure the real ones are there.
  ensure_xcode_clt
  if have brew; then
    ok "Homebrew"
    return 0
  fi
  info "installing Homebrew (it asks for your password)"
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] run the Homebrew installer"
    return 0
  fi
  local tmp
  tmp=$(mktemp_dir)
  download https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$tmp/install.sh" ||
    die "couldn't download the Homebrew installer"
  /bin/bash "$tmp/install.sh" || die "the Homebrew install failed"
  load_brew_env || die "Homebrew installed, but brew isn't in /opt/homebrew or /usr/local"
  note "add Homebrew to your shell: eval \"\$($(command -v brew) shellenv)\""
}

# pm_install "pkg pkg ...": install with the platform's package manager.
pm_install() {
  local p
  case "$PM" in
    brew)
      for p in $1; do
        case "$p" in
          cask:*) run brew install --cask "${p#cask:}" || return 1 ;;
          *) run brew install "$p" || return 1 ;;
        esac
      done
      ;;
    apt)
      if [ "$APT_UPDATED" = 0 ]; then
        as_root apt-get update || return 1
        APT_UPDATED=1
      fi
      # shellcheck disable=SC2086 # $1 is a package list
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $1
      ;;
    dnf)
      # shellcheck disable=SC2086
      as_root dnf install -y $1
      ;;
    pacman)
      # shellcheck disable=SC2086
      if ! as_root pacman -S --needed --noconfirm $1; then
        info "if pacman couldn't find a package, run 'sudo pacman -Syu' and re-run this script"
        return 1
      fi
      ;;
  esac
}

# --- custom probes (deps.tsv "@name" in the probe column) ---------------------

probe_cc() {
  if [ "$PLATFORM" = mac ]; then xcode-select -p >/dev/null 2>&1; else have cc || have gcc; fi
}

probe_python() { have python3 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; }

# Debian and Ubuntu split ensurepip into python3-venv; without it, venvs fail.
probe_pyvenv() { have python3 && python3 -c 'import ensurepip, venv' 2>/dev/null; }

probe_dotnet() { have dotnet && [ -n "$(dotnet --list-sdks 2>/dev/null)" ]; }

# ruby.lua runs ruby-lsp from the rbenv shim (or PATH); Mason's Ruby tools need gem.
probe_ruby() {
  have gem || return 1
  [ -x "$HOME/.rbenv/shims/ruby-lsp" ] || have ruby-lsp
}

# --- custom installers (deps.tsv "@name" in a package column) ----------------

install_xcode_clt() { ensure_xcode_clt; }

arch_name() {
  case "$ARCH" in
    x86_64 | amd64) echo "$1" ;;
    aarch64 | arm64) echo "$2" ;;
    *) return 1 ;;
  esac
}

# Official release tarball: distro packages are often older than LazyVim needs.
install_neovim() {
  local arch file url tmp
  arch=$(arch_name x86_64 arm64) || { warn "no official Neovim build for $ARCH" && return 1; }
  file="nvim-linux-$arch.tar.gz"
  url="https://github.com/neovim/neovim/releases/download/stable"
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] download $url/$file into $OPT_DIR/nvim, link $LOCAL_BIN/nvim"
    return 0
  fi
  tmp=$(mktemp_dir) || return 1
  download "$url/$file" "$tmp/$file" || return 1
  verify_sha256 "$tmp/$file" "$url/shasum.txt" "$file" || return 1
  tar -xzf "$tmp/$file" -C "$tmp" || return 1
  mkdir -p "$OPT_DIR" "$LOCAL_BIN" || return 1
  rm -rf "$OPT_DIR/nvim"
  mv "$tmp/nvim-linux-$arch" "$OPT_DIR/nvim" || return 1
  ln -sf "$OPT_DIR/nvim/bin/nvim" "$LOCAL_BIN/nvim" || return 1
  BIN_TOUCHED=1
}

install_lazygit() {
  local arch tag file base tmp
  arch=$(arch_name x86_64 arm64) || { warn "no lazygit build for $ARCH" && return 1; }
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] download the latest lazygit release into $LOCAL_BIN"
    return 0
  fi
  tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/jesseduffield/lazygit/releases/latest) || return 1
  tag=${tag##*/}
  file="lazygit_${tag#v}_Linux_${arch}.tar.gz"
  base="https://github.com/jesseduffield/lazygit/releases/download/$tag"
  tmp=$(mktemp_dir) || return 1
  download "$base/$file" "$tmp/$file" || return 1
  verify_sha256 "$tmp/$file" "$base/checksums.txt" "$file" || return 1
  tar -xzf "$tmp/$file" -C "$tmp" lazygit || return 1
  mkdir -p "$LOCAL_BIN" || return 1
  install -m 755 "$tmp/lazygit" "$LOCAL_BIN/lazygit" || return 1
  BIN_TOUCHED=1
}

# Current Node.js LTS from nodejs.org: apt's Node is too old on Ubuntu 24.04 and
# Debian 12, and this avoids adding a third-party apt repository.
install_node() {
  local arch ver file base tmp b
  arch=$(arch_name x64 arm64) || { warn "no Node.js build for $ARCH" && return 1; }
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] download the current Node.js LTS into $OPT_DIR/node, link node/npm/npx into $LOCAL_BIN"
    return 0
  fi
  tmp=$(mktemp_dir) || return 1
  download https://nodejs.org/dist/index.tab "$tmp/index.tab" || return 1
  ver=$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "lts") c = i; next }
    c && $c != "-" { print $1; exit }' "$tmp/index.tab")
  [ -n "$ver" ] || { warn "couldn't find the current Node.js LTS" && return 1; }
  file="node-$ver-linux-$arch.tar.gz"
  base="https://nodejs.org/dist/$ver"
  download "$base/$file" "$tmp/$file" || return 1
  verify_sha256 "$tmp/$file" "$base/SHASUMS256.txt" "$file" || return 1
  tar -xzf "$tmp/$file" -C "$tmp" || return 1
  mkdir -p "$OPT_DIR" "$LOCAL_BIN" || return 1
  rm -rf "$OPT_DIR/node"
  mv "$tmp/node-$ver-linux-$arch" "$OPT_DIR/node" || return 1
  for b in node npm npx corepack; do
    if [ -e "$OPT_DIR/node/bin/$b" ]; then ln -sf "$OPT_DIR/node/bin/$b" "$LOCAL_BIN/$b" || return 1; fi
  done
  BIN_TOUCHED=1
}

# Microsoft's installer into ~/.dotnet works the same on every distro.
install_dotnet() {
  local tmp
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] dotnet-install.sh --channel LTS --install-dir $HOME/.dotnet"
    return 0
  fi
  tmp=$(mktemp_dir) || return 1
  download https://dot.net/v1/dotnet-install.sh "$tmp/dotnet-install.sh" || return 1
  bash "$tmp/dotnet-install.sh" --channel LTS --install-dir "$HOME/.dotnet" || return 1
  mkdir -p "$LOCAL_BIN" || return 1
  ln -sf "$HOME/.dotnet/dotnet" "$LOCAL_BIN/dotnet" || return 1
  BIN_TOUCHED=1
  if [ -z "${DOTNET_ROOT:-}" ]; then
    export DOTNET_ROOT="$HOME/.dotnet"
    note "set DOTNET_ROOT=\$HOME/.dotnet in your shell profile; Mason's .NET tools (csharpier, fantomas) need it to find the runtime"
  fi
}

ruby_build_deps() {
  case "$PM" in
    apt) pm_install "autoconf patch build-essential libssl-dev libyaml-dev libreadline-dev zlib1g-dev libgmp-dev libffi-dev" ;;
    dnf) pm_install "autoconf gcc make patch bzip2 openssl-devel libyaml-devel libffi-devel readline-devel zlib-devel gmp-devel" ;;
    pacman) pm_install "base-devel libffi libyaml openssl zlib" ;;
    brew) return 0 ;; # Homebrew's ruby-build formula brings its own
  esac
}

# rbenv + the latest stable Ruby + ruby-lsp, matching lua/plugins/ruby.lua.
# Reuses an existing rbenv and never changes a global Ruby you already set.
install_ruby() {
  local version
  if ! have rbenv; then
    if [ "$PM" = brew ]; then
      pm_install "rbenv ruby-build" || return 1
    elif [ ! -d "$HOME/.rbenv" ]; then
      run git clone --depth 1 https://github.com/rbenv/rbenv.git "$HOME/.rbenv" || return 1
    fi
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] rbenv install <latest stable Ruby> if none is installed; gem install ruby-lsp"
    return 0
  fi
  hash -r
  have rbenv || { warn "rbenv isn't on PATH" && return 1; }
  if ! rbenv install --list >/dev/null 2>&1; then
    if [ "$PM" = brew ]; then
      pm_install ruby-build || return 1
    else
      git clone --depth 1 https://github.com/rbenv/ruby-build.git "$(rbenv root)/plugins/ruby-build" || return 1
    fi
  fi

  version=$(rbenv version-name 2>/dev/null || true)
  if [ -z "$version" ] || [ "$version" = system ]; then
    version=$(rbenv versions --bare 2>/dev/null | tail -n 1)
    if [ -z "$version" ]; then
      ruby_build_deps || return 1
      version=$(rbenv install --list 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | tail -n 1)
      [ -n "$version" ] || { warn "couldn't find a Ruby version to install" && return 1; }
      info "building Ruby $version with rbenv (this takes several minutes)"
      rbenv install -s "$version" || return 1
      rbenv global "$version" || return 1
      note "rbenv's global Ruby is now $version"
    fi
  fi
  info "installing ruby-lsp into Ruby $version"
  RBENV_VERSION=$version rbenv exec gem install --no-document ruby-lsp || return 1
  rbenv rehash
  case ":$ORIG_PATH:" in
    *":$HOME/.rbenv/shims:"*) ;;
    *) note "add rbenv to your shell profile (eval \"\$(rbenv init -)\"); Mason's Ruby tools need its gem on PATH" ;;
  esac
}

install_rustup() {
  local tmp
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] run rustup-init -y --no-modify-path"
    return 0
  fi
  tmp=$(mktemp_dir) || return 1
  download https://sh.rustup.rs "$tmp/rustup-init.sh" || return 1
  sh "$tmp/rustup-init.sh" -y --no-modify-path || return 1
  path_note "$HOME/.cargo/bin"
}

# Installed as `bazel`, the command lua/plugins/bazel.lua runs.
install_bazelisk() {
  local arch
  arch=$(arch_name amd64 arm64) || { warn "no Bazelisk build for $ARCH" && return 1; }
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] download bazelisk-linux-$arch to $LOCAL_BIN/bazel"
    return 0
  fi
  mkdir -p "$LOCAL_BIN" || return 1
  download "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-$arch" "$LOCAL_BIN/bazel" || return 1
  chmod 755 "$LOCAL_BIN/bazel" || return 1
  BIN_TOUCHED=1
}

install_pymobiledevice3() {
  run pipx install pymobiledevice3 || return 1
  BIN_TOUCHED=1
}

# --- steps --------------------------------------------------------------------

probe() {
  local cmd v
  case "$1" in @*)
    "probe_${1#@}"
    return
    ;;
  esac
  cmd=$(first_cmd "$1") || return 1
  [ "$2" = - ] && return 0
  v=$(version_of "$cmd")
  [ -n "$v" ] && version_ge "$v" "$2"
}

record_failure() {
  FAILED="$FAILED, $1"
}

# ensure_dep NAME PROBE MIN SPEC
ensure_dep() {
  local name=$1 probe_spec=$2 min=$3 spec=$4 label=$1
  [ "$min" = - ] || label="$name >= $min"
  if probe "$probe_spec" "$min"; then
    ok "$label"
    return 0
  fi
  case "$spec" in
    "?")
      warn "$label: no $PM package; install it yourself"
      record_failure "$name"
      return 0
      ;;
    @*)
      info "installing $label"
      if ! "install_${spec#@}"; then
        warn "$label: install failed"
        record_failure "$name"
        return 0
      fi
      ;;
    *)
      info "installing $label ($spec)"
      if ! pm_install "$spec"; then
        warn "$label: $PM install failed"
        record_failure "$name"
        return 0
      fi
      ;;
  esac
  [ "$DRY_RUN" = 1 ] && return 0
  hash -r
  if probe "$probe_spec" "$min"; then
    ok "$label"
    INSTALLED="$INSTALLED, $name"
  else
    warn "$label: still missing or too old after installing; check PATH"
    record_failure "$name"
  fi
}

install_deps() {
  local group name probe_spec min brew apt dnf pacman spec current=""
  # fd 3, so installers that read stdin (sudo, Homebrew) can't eat the file.
  # The last column (winget) is for install.ps1 and lands in `_`.
  while IFS="$TAB" read -r group name probe_spec min brew apt dnf pacman _ <&3; do
    case "$group" in "" | "#"* | group) continue ;; esac
    in_groups "$group" || continue
    case "$PM" in
      brew) spec=$brew ;;
      apt) spec=$apt ;;
      dnf) spec=$dnf ;;
      pacman) spec=$pacman ;;
    esac
    spec=${spec%"$CR"}
    [ "$spec" = - ] && continue
    if [ "$group" != "$current" ]; then
      step "Group: $group"
      current=$group
    fi
    ensure_dep "$name" "$probe_spec" "$min" "$spec"
  done 3<"$DEPS_FILE"
}

# Debian and Ubuntu name the fd binary fdfind.
link_fd() {
  in_groups core || return 0
  if ! have fd && have fdfind; then
    run mkdir -p "$LOCAL_BIN"
    run ln -sf "$(command -v fdfind)" "$LOCAL_BIN/fd"
    BIN_TOUCHED=1
    info "linked fdfind to $LOCAL_BIN/fd"
  fi
}

exists() { [ -e "$1" ]; }

font_installed() {
  if [ "$PLATFORM" = mac ]; then
    exists "$HOME/Library/Fonts/${FONT}NerdFont"* || exists "/Library/Fonts/${FONT}NerdFont"*
  else
    exists "$1/${FONT}NerdFont"* || { have fc-list && fc-list 2>/dev/null | grep -qi "$FONT Nerd Font"; }
  fi
}

install_font() {
  local dir tmp
  [ "$FONT" = none ] && return 0
  step "Nerd Font ($FONT)"
  if [ "$PLATFORM" = mac ]; then
    dir="$HOME/Library/Fonts"
  else
    if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
      info "no graphical session; skipped (install the font where your terminal runs)"
      return 0
    fi
    dir="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/${FONT}NerdFont"
  fi
  if font_installed "$dir"; then
    ok "$FONT Nerd Font"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] download $FONT.zip from the nerd-fonts releases into $dir"
    return 0
  fi
  tmp=$(mktemp_dir)
  if ! download "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$FONT.zip" "$tmp/font.zip" ||
    ! unzip -q -o "$tmp/font.zip" -d "$tmp/x"; then
    warn "couldn't download or unpack $FONT.zip; check the name against the nerd-fonts releases"
    return 0
  fi
  mkdir -p "$dir"
  find "$tmp/x" -type f \( -name '*.ttf' -o -name '*.otf' \) -exec cp {} "$dir/" \;
  if [ "$PLATFORM" = linux ] && have fc-cache; then fc-cache -f "$dir" >/dev/null 2>&1 || true; fi
  ok "$FONT Nerd Font"
  note "select \"$FONT Nerd Font\" in your terminal's settings"
}

same_dir() {
  [ -d "$1" ] && [ -d "$2" ] && [ "$(cd -P "$1" && pwd)" = "$(cd -P "$2" && pwd)" ]
}

backup() {
  local dest="$1.bak.$STAMP"
  run mv "$1" "$dest"
  info "moved $1 to $dest"
  BACKUPS="$BACKUPS
  - $dest"
}

place_config() {
  local d
  step "Config ($CONFIG_DIR)"
  if same_dir "$CONFIG_DIR" "$REPO_DIR"; then
    ok "already in place"
  else
    if [ -e "$CONFIG_DIR" ] || [ -L "$CONFIG_DIR" ]; then backup "$CONFIG_DIR"; fi
    run mkdir -p "$(dirname "$CONFIG_DIR")"
    run ln -s "$REPO_DIR" "$CONFIG_DIR"
    ok "linked to $REPO_DIR"
  fi
  if [ "$FRESH" = 1 ]; then
    for d in "$DATA_DIR" "$STATE_DIR" "$CACHE_DIR"; do
      if [ -e "$d" ]; then backup "$d"; fi
    done
  fi
}

# Run outside a checkout (bash -c "$(curl ...)"): clone into the config dir and
# hand over to the copy of this script there.
standalone() {
  step "Fetching the config"
  if ! have git; then
    pm_install git || die "git is needed to clone the config"
  fi
  if [ -f "$CONFIG_DIR/scripts/install.sh" ] && [ -f "$CONFIG_DIR/scripts/deps.tsv" ]; then
    ok "found a checkout at $CONFIG_DIR"
  else
    if [ -e "$CONFIG_DIR" ] || [ -L "$CONFIG_DIR" ]; then backup "$CONFIG_DIR"; fi
    run mkdir -p "$(dirname "$CONFIG_DIR")"
    run git clone "$REPO_URL" "$CONFIG_DIR" || die "git clone $REPO_URL failed"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] continue with $CONFIG_DIR/scripts/install.sh"
    exit 0
  fi
  [ -f "$CONFIG_DIR/scripts/install.sh" ] || die "$REPO_URL has no scripts/install.sh; is it the right repository?"
  rm -rf "$TMP_ROOT"
  exec bash "$CONFIG_DIR/scripts/install.sh" "$@"
}

setup_python_venv() {
  local venv="$DATA_DIR/venv"
  in_groups python || return 0
  step "Python provider (pynvim)"
  if [ -x "$venv/bin/python" ] && "$venv/bin/python" -c 'import pynvim' 2>/dev/null; then
    ok "$venv"
    return 0
  fi
  if ! probe_python; then
    warn "python3 isn't available; skipped the provider venv"
    return 0
  fi
  run mkdir -p "$DATA_DIR"
  if run python3 -m venv "$venv" && run "$venv/bin/python" -m pip install --quiet --upgrade pip pynvim; then
    ok "$venv"
  else
    warn "couldn't create the pynvim venv at $venv"
  fi
}

health_check() {
  local log="$TMP_ROOT/health.txt"
  NVIM_HEALTH_LOG="$log" nvim --headless "+checkhealth lazyvim" \
    "+lua vim.fn.writefile(vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.env.NVIM_HEALTH_LOG)" \
    +qa >/dev/null 2>&1 || true
  if [ ! -s "$log" ]; then
    warn "couldn't run checkhealth lazyvim"
  elif grep -q 'ERROR' "$log"; then
    warn "checkhealth lazyvim reported errors:"
    grep 'ERROR' "$log" | sed 's/^ */           /' >&2
  else
    ok "checkhealth lazyvim: no errors"
  fi
}

warmup() {
  if [ "$WARMUP" = 0 ]; then
    info "warm-up skipped (--no-warmup)"
    return 0
  fi
  step "Warm-up: plugins, Treesitter parsers, Mason packages"
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] nvim --headless \"+Lazy! restore\" +qa"
    info "[dry-run] nvim --headless (scripts/warmup.lua)"
    info "[dry-run] nvim --headless \"+checkhealth lazyvim\""
    return 0
  fi
  if ! probe nvim "$NVIM_MIN"; then
    warn "Neovim >= $NVIM_MIN isn't available; skipped the warm-up"
    return 0
  fi
  export NVIM_APPNAME="$APPNAME"
  info "checking out the plugin versions in lazy-lock.json"
  nvim --headless "+Lazy! restore" +qa || warn "Lazy restore failed"
  info "installing parsers and Mason packages; this takes a few minutes"
  if NVIM_WARMUP="$CONFIG_DIR/scripts/warmup.lua" nvim --headless -c "lua dofile(vim.env.NVIM_WARMUP)"; then
    ok "warm-up"
  else
    warn "the warm-up reported failures (listed above)"
  fi
  health_check
}

summary() {
  step "Summary"
  if [ -n "$INSTALLED" ]; then printf '  installed: %s\n' "${INSTALLED#, }"; fi
  if [ -n "$FAILED" ]; then printf '  %snot installed:%s %s\n' "$YELLOW" "$RESET" "${FAILED#, }"; fi
  if [ -n "$BACKUPS" ]; then printf '  moved aside:%s\n' "$BACKUPS"; fi
  if [ "$BIN_TOUCHED" = 1 ]; then path_note "$LOCAL_BIN"; fi
  if [ -n "$NOTES" ]; then printf '\n  To finish:%s\n' "$NOTES"; fi
  if [ -n "$WARNINGS" ]; then printf '\n  %sWarnings:%s%s\n' "$YELLOW" "$RESET" "$WARNINGS"; fi
  if [ "$APPNAME" = nvim ]; then
    printf '\n  Start Neovim with: nvim\n'
  else
    printf '\n  Start Neovim with: NVIM_APPNAME=%s nvim\n' "$APPNAME"
  fi
}

main() {
  parse_args "$@"
  detect_platform
  check_user
  setup_path
  select_groups
  resolve_dirs
  STAMP=$(date +%Y%m%d-%H%M%S)
  TMP_ROOT=$(mktemp -d)
  trap 'rm -rf "$TMP_ROOT"' EXIT
  locate_repo

  printf '%sNeovim config setup%s (%s, %s)\n' "$BOLD" "$RESET" "$PLATFORM" "$PM"
  printf '  groups:  %s\n  config:  %s\n' "$SELECTED" "$CONFIG_DIR"
  if [ "$DRY_RUN" = 1 ]; then printf '  dry run: nothing will be changed\n'; fi

  bootstrap
  if [ -z "$REPO_DIR" ]; then standalone "$@"; fi
  install_deps
  link_fd
  install_font
  place_config
  setup_python_venv
  warmup
  summary
}

main "$@"
