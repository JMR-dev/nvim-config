# nvim-config

My Neovim setup, built on [LazyVim](https://lazyvim.github.io). Two scripts set it
up on a new machine: `scripts/install.sh` for macOS and Linux, `scripts/install.ps1`
for Windows. Both:

1. install the tools the config needs (Neovim, ripgrep, fd, a C compiler for
   Treesitter, language runtimes for the enabled LazyVim extras, a Nerd Font),
2. put the config where Neovim looks for it, backing up whatever was there,
3. create the Python provider venv with `pynvim`,
4. run Neovim headless to check out the plugin versions in `lazy-lock.json` and
   pre-install the Treesitter parsers and Mason packages, then run
   `:checkhealth lazyvim`.

Re-running is safe: anything already installed is skipped.

## Quick start

From a clone (any location works; the script links it into place):

```sh
git clone https://github.com/JMR-dev/nvim-config.git
./nvim-config/scripts/install.sh            # macOS, Linux
```

```powershell
git clone https://github.com/JMR-dev/nvim-config.git
powershell -ExecutionPolicy Bypass -File nvim-config\scripts\install.ps1   # Windows
```

Without cloning first (the script clones into the config directory, then runs
that copy):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/JMR-dev/nvim-config/main/scripts/install.sh)" install.sh --preset default
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/JMR-dev/nvim-config/main/scripts/install.ps1))) -Preset default
```

The one-liners only work while the repository is public. Use `bash -c` rather
than `curl | bash`: the installers it calls (sudo, Homebrew) need the terminal on
standard input.

Try it without touching your current setup first:

```sh
./scripts/install.sh --dry-run                 # show what would happen
./scripts/install.sh --appname nvim-test       # install beside it, then:
NVIM_APPNAME=nvim-test nvim
```

## Options

| install.sh | install.ps1 | Effect |
|---|---|---|
| `--preset NAME` | `-Preset NAME` | `minimal`, `default` or `full` (below) |
| `--with a,b` | `-With a,b` | add groups |
| `--without a,b` | `-Without a,b` | remove groups |
| `--appname NAME` | `-AppName NAME` | install as `NVIM_APPNAME=NAME` |
| `--fresh` | `-Fresh` | also move aside Neovim's data, state and cache dirs |
| `--font NAME` | `-Font NAME` | Nerd Font from the [nerd-fonts releases](https://github.com/ryanoasis/nerd-fonts/releases) (default `JetBrainsMono`, `none` skips) |
| `--no-warmup` | `-NoWarmup` | skip the headless plugin, parser and Mason install |
| `--repo URL` | `-RepoUrl URL` | repository to clone in standalone mode |
| `--allow-root` | | allow running as root, for containers |
| | `-EnableLongPaths` | set git `core.longpaths`; from an elevated shell, also Windows' `LongPathsEnabled` |
| `--dry-run` | `-DryRun` | print the plan, change nothing |

## Groups

`lazyvim.json` enables every language extra on every machine. Mason installs
some packages through a language's own toolchain (npm, pip, `go install`, `gem`,
`dotnet tool`); without that toolchain, the install fails and LazyVim retries it
every session. The `default` preset covers those toolchains. The opt-in groups
only matter once you use that language.

| Group | Installs | Preset |
|---|---|---|
| core | Neovim ≥ 0.11.2, git, curl, unzip, C compiler, ripgrep, fd, fzf, lazygit; 7-Zip on Windows | all |
| node | Node.js ≥ 22 | all |
| python | Python 3, plus the `pynvim` venv | all |
| go | Go | default, full |
| dotnet | .NET SDK | default, full |
| ruby | rbenv + latest Ruby + `ruby-lsp` (RubyInstaller on Windows) | default, full |
| java | JDK 21 (jdtls, Kotlin) | full |
| php | PHP | full |
| beam | Erlang/OTP, Elixir (ELP, Expert, credo) | full |
| rust | rustup | full |
| tools | Zig, Terraform, Helm, Bazelisk | full |
| swift | Swift toolchain, SwiftLint | full |
| xcode | xcp, xcode-build-server, xcbeautify, jq, coreutils, pipx, pymobiledevice3 | full (macOS only) |

Packages come from Homebrew on macOS, apt, dnf or pacman on Linux, and winget on
Windows. A few come from upstream releases instead because distro packages are
missing or too old, for example Neovim, lazygit and Node.js on Debian and Ubuntu;
those three are checked against their release's SHA-256 file.
Where no package exists (Swift on Linux, Terraform on apt, ...) the script says
so and moves on.

All of this lives in `scripts/deps.tsv`, which both scripts read. To add a tool,
add a row there.

## What it changes

- **Config:** links the checkout to `~/.config/nvim` (a junction at
  `%LOCALAPPDATA%\nvim` on Windows). An existing config is renamed to
  `nvim.bak.<timestamp>`, never deleted. `--fresh` does the same to the data,
  state and cache directories.
- **Your home directory:** binaries from upstream releases go in `~/.local/opt`
  and `~/.local/bin`; .NET (Linux) in `~/.dotnet`; rbenv in `~/.rbenv`; rustup in
  `~/.cargo`.
- **Shell profiles:** never edited. The summary lists anything you need to add,
  such as `~/.local/bin` on PATH, `DOTNET_ROOT`, or `rbenv init`.
- **Windows PATH:** the 7-Zip folder is appended to your user PATH, because
  Mason looks for `7z` there and the 7-Zip installer doesn't add it.

## After installing

- Set your terminal's font to the installed Nerd Font.
- Open a new terminal so PATH changes apply, then start `nvim`.
- On Windows, `bazel.lua` runs `bazel`, but winget installs Bazelisk as
  `bazelisk.exe`; copy it to `bazel.exe` if you use Bazel.

## Troubleshooting

- **A Mason package failed:** run the script again, or open `:Mason` and press
  `i` on the package. Packages that need a runtime from a group you skipped are
  expected to fail.
- **Ruby on Windows:** if `gem install ruby-lsp` fails, the script runs
  `ridk install 1 3` to set up RubyInstaller's MSYS2 build tools, then tries once
  more.
- **Arch Linux:** if pacman can't find a package, run `sudo pacman -Syu` first.
