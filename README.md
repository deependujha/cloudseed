# cloudseed

[![CI](https://github.com/deependujha/cloudseed/actions/workflows/ci.yml/badge.svg)](https://github.com/deependujha/cloudseed/actions/workflows/ci.yml)

One command to make a blank Ubuntu cloud VM feel like home.

Ubuntu 22.04 / 24.04 · x86_64 / arm64 · root or sudo user · idempotent

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/deependujha/cloudseed/main/install.sh | bash
```

With no flags you get an interactive checklist. Toggle steps by number, then press Enter.

To skip the menu, pass flags after `bash -s --`:

```bash
# everything, no questions
curl -fsSL https://raw.githubusercontent.com/deependujha/cloudseed/main/install.sh | bash -s -- --all --yes

# just these two steps
curl -fsSL https://raw.githubusercontent.com/deependujha/cloudseed/main/install.sh | bash -s -- --update --nvim
```

When it finishes, run `exec $SHELL` to load the helpers.

## Flags

| Flag | What it does |
|---|---|
| `--all` | Run every step |
| `--update` | `apt-get update` |
| `--upgrade` | `apt-get upgrade -y`, non-interactive, keeps your existing config files |
| `--git` | Install git. When interactive, offers to set `user.name` / `user.email` if unset |
| `--tools` | Install the apt CLI tools (list below) |
| `--uv` | Install uv and set Python as the default `python` |
| `--helpers` | Copy `contents/` to `~/shell-helpers` and wire up bash/zsh |
| `--nvim` | Install the latest stable Neovim and [nvim-config](https://github.com/deependujha/nvim-config) |
| `--nvim-sync` | Also run a headless `Lazy! sync` (slow). Implies `--nvim` |
| `--python <ver>` | Python version for `--uv` (default `3.12`) |
| `--ref <branch/tag>` | cloudseed ref to fetch `contents/` from when piped (default `main`) |
| `-y`, `--yes` | Non-interactive, accept defaults |
| `--dry-run` | Print what would happen and change nothing |
| `--uninstall` | Remove the rc blocks and `~/shell-helpers` |
| `-h`, `--help` | Help |

How flags are handled:

- **Any step flag:** only those steps run, with no menu.
- **No flags, in a terminal:** shows the menu.
- **`--yes` with no step flags:** runs the default steps (all except `upgrade`).
- **No flags, no terminal, no `--yes`:** prints help and exits non-zero. It never does work you didn't ask for.

## What it does

Steps run in this order. Each one is safe to re-run.

| Step | Details | Touches in `$HOME` |
|---|---|---|
| **update** | `apt-get update` | — |
| **upgrade** | `apt-get upgrade -y` with `DEBIAN_FRONTEND=noninteractive`, `--force-confdef --force-confold`, `NEEDRESTART_MODE=a`. Never stops at a config-file prompt. Off by default. | — |
| **git** | `apt-get install git`. If `user.name` is unset and you're interactive, asks for name and email. | `~/.gitconfig` (only if you answer) |
| **tools** | `tree curl wget unzip jq htop tmux ripgrep fd-find fzf build-essential ncdu nvtop ca-certificates`. Only installs what's missing. Symlinks `fd` → `fdfind`. | `~/.local/bin/fd` |
| **uv** | Official astral.sh installer, with rc-file editing turned off. Then `uv python install <ver> --default`. If that uv can't set a default, cloudseed sets `UV_PYTHON=<ver>` through `python.sh` instead. | `~/.local/bin/{uv,uvx,python*}`, `~/.local/share/uv`, `~/.cloudseed/uv-python` (fallback only) |
| **helpers** | Copies `contents/` into `~/shell-helpers/`. Adds one managed block to `~/.bashrc`, and to `~/.zshrc` if that file exists or zsh is installed. Backs up each rc file once before the first change. | `~/shell-helpers/`, `~/.bashrc`, `~/.zshrc`, `*.cloudseed.bak` |
| **nvim** | Latest stable Neovim release tarball from GitHub (not apt). The asset is chosen from the releases API for your arch. Also installs the `tree-sitter` CLI, which nvim-treesitter `main` needs. Clones nvim-config, or runs `git pull --ff-only` if it's already there. Existing nvim dirs are moved to `*.bak.<timestamp>`, never deleted. Needs `tools` and `git`, and is skipped with a reason if they're missing. | `~/.local/opt/nvim`, `~/.local/bin/{nvim,tree-sitter}`, `~/.config/nvim`, plus backups of `~/.config/nvim`, `~/.local/share/nvim`, `~/.local/state/nvim`, `~/.cache/nvim` |

This is the managed block:

```sh
# >>> cloudseed >>>
for f in "$HOME/shell-helpers"/*.sh; do [ -r "$f" ] && . "$f"; done
# <<< cloudseed <<<
```

If the block already exists, cloudseed replaces it in place and never adds a second copy. If nothing changed, the file isn't rewritten.

**Other behavior:**

- Every run appends to a log at `~/.cloudseed/install.log`. When a step fails, you see its last 20 log lines.
- A failed step doesn't stop the independent steps after it. The exit code is non-zero if any step failed.
- Under `sudo`, cloudseed sets up `$SUDO_USER`'s home, not `/root`, and gives that user ownership of everything it creates.
- The only network hosts it contacts are apt mirrors, GitHub, and astral.sh.

## Customising

`contents/` holds plain shell files that both bash and zsh source:

| File | Purpose |
|---|---|
| `shortcuts.sh` | Navigation, listing and git aliases (`gs`, `gc`, `gp`, `ll`, `..`, …). Every alias has a comment. |
| `python.sh` | uv aliases (`uvr`, `uva`, `uvs`, `act`, …) |
| `cuda_specifics.sh` | `CUDA_HOME`/`PATH`/`LD_LIBRARY_PATH`, `gpu`, `gpuw`, `cuda_on 0,1`, … Does nothing if `nvidia-smi` isn't installed. |
| `path.sh` | Puts `~/.local/bin` on `PATH` and sets `EDITOR=nvim` once nvim is installed |

**Any `*.sh` you add to `contents/` loads automatically.** You don't need to edit an rc file. Keep new files POSIX-ish. For anything shell-specific, guard it with `[ -n "$BASH_VERSION" ]` or `[ -n "$ZSH_VERSION" ]`.

To change the apt tools, edit the `TOOLS_PACKAGES` array at the top of `install.sh`.

## Local development

```bash
git clone https://github.com/deependujha/cloudseed && cd cloudseed
./install.sh --dry-run --all --yes   # see the plan
./install.sh                          # menu
```

When `contents/` sits next to the script, cloudseed uses that copy. When piped, it downloads `contents/` for `--ref` from GitHub's codeload as a tarball, so git isn't needed.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/deependujha/cloudseed/main/install.sh | bash -s -- --uninstall
```

This removes the managed block from `~/.bashrc` and `~/.zshrc`, and deletes `~/shell-helpers`.

It deliberately leaves these in place:

- apt packages
- uv and Python
- Neovim and `~/.config/nvim`
- the `*.bak` backups
- `~/.cloudseed/` (the log)

## About `curl | bash`

Piping a script into a shell means trusting it, so read it first:

```bash
curl -fsSL https://raw.githubusercontent.com/deependujha/cloudseed/main/install.sh | less
```

This script is reasonable to pipe because:

- It's a single file you can read in a few minutes.
- It's written for throwaway cloud VMs.
- It never does anything you didn't select.
- `--dry-run` shows the whole plan before anything runs.
- The whole script is wrapped in functions that run from the last line, so a cut-off download can't run half a script.

To pin to a version you've reviewed, use a tag or commit in the URL instead of `main`.
