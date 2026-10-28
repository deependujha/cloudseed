#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2329  # os-release is runtime-only; step_* are called by name
# cloudseed — one command to make a blank Ubuntu cloud VM feel like home.
#
#   curl -fsSL https://raw.githubusercontent.com/deependujha/cloudseed/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/deependujha/cloudseed/main/install.sh | bash -s -- --all --yes
#
# Everything lives in functions and `main "$@"` is the last line, so bash has
# read the whole script before anything runs (matters under `curl | bash`).

set -Eeuo pipefail
shopt -s inherit_errexit

# ============================================================== edit me ==
# apt packages installed by the `tools` step.
TOOLS_PACKAGES=(
  tree curl wget unzip jq htop tmux ripgrep fd-find fzf
  build-essential ncdu nvtop ca-certificates
)
# =========================================================================

VERSION="0.1.0"
REPO="deependujha/cloudseed"
NVIM_CONFIG_URL="https://github.com/deependujha/nvim-config"

# Execution order. `tools` runs before `uv` because uv's installer needs curl.
STEPS=(update upgrade git tools uv helpers vim nvim)

declare -A STEP_DESC=(
  [update]="apt-get update"
  [upgrade]="apt-get upgrade (slow)"
  [git]="install git, offer to set name/email"
  [tools]="CLI tools: ripgrep, fd, fzf, jq, tmux, htop, build-essential…"
  [uv]="uv + Python (default), via astral.sh"
  [helpers]="copy contents/ → ~/shell-helpers, wire bash/zsh"
  [vim]="vim + ~/.vimrc + vim-plug (vim-polyglot)"
  [nvim]="latest Neovim + deependujha/nvim-config (AstroNvim)"
)
declare -A STEP_DEFAULT=(
  [update]=1 [upgrade]=0 [git]=1 [tools]=1 [uv]=1 [helpers]=1 [vim]=1 [nvim]=1
)
# Steps that need root (directly or via sudo).
declare -A STEP_NEEDS_ROOT=([update]=1 [upgrade]=1 [git]=1 [tools]=1 [vim]=1)
# Commands a step needs before it can run, and which step provides them.
declare -A STEP_REQUIRES=([uv]="curl" [vim]="curl git" [nvim]="curl tar gzip git rg cc unzip")
declare -A CMD_PROVIDER=(
  [curl]=tools [rg]=tools [cc]=tools [unzip]=tools [git]=git [tar]=base [gzip]=base
)

BLOCK_START="# >>> cloudseed >>>"
BLOCK_END="# <<< cloudseed <<<"
# shellcheck disable=SC2016  # expanded by the rc file, not here
BLOCK_BODY='for f in "$HOME/shell-helpers"/*.sh; do [ -r "$f" ] && . "$f"; done'

# ------------------------------------------------------------------ state
declare -A SELECTED=() RESULT=() DURATION=() REASON=()
PYTHON_VERSION="3.12"
REF="main"
REF_SET=0
YES=0
DRY_RUN=0
UNINSTALL=0
NVIM_SYNC=0
ANY_STEP_FLAG=0
CAN_PROMPT=0
INTERACTIVE=0
HAVE_ROOT=0
SUDO_KEEPALIVE_PID=""
WORK_DIR=""
LOG=""
TS="$(date +%Y%m%d-%H%M%S)"

# ===================================================================== UI ==

setup_colors() {
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" RESET=""
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ] || return 0
  if command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    BOLD="$(tput bold)" DIM="$(tput dim)" RESET="$(tput sgr0)"
    RED="$(tput setaf 1)" GREEN="$(tput setaf 2)" YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)" MAGENTA="$(tput setaf 5)" CYAN="$(tput setaf 6)"
  elif [ "${TERM:-dumb}" != dumb ]; then
    BOLD=$'\e[1m' DIM=$'\e[2m' RESET=$'\e[0m'
    RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m'
    BLUE=$'\e[34m' MAGENTA=$'\e[35m' CYAN=$'\e[36m'
  fi
}

# All user-facing output goes to fd 3 (the real terminal/stdout). Inside a
# step, fd 1 and 2 point at the log file.
log()   { if [ -n "$LOG" ]; then printf '%s\n' "$*" >>"$LOG"; fi; }
say()   { printf '%s\n' "$*" >&3; }
info()  { printf '  %s·%s %s\n' "$DIM" "$RESET" "$*" >&3; log "[info] $*"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&3; log "[warn] $*"; }
die()   { printf '%s✗ %s%s\n' "$RED" "$*" "$RESET" >&3; exit 1; }
would() { printf '  %swould:%s %s\n' "$MAGENTA" "$RESET" "$*" >&3; }

fmt_dur() {
  local s=$1
  if [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

banner() {
  local os arch gpu
  os="$(os_pretty)"
  arch="$(uname -m)"
  gpu="$(gpu_name)"
  say ""
  say "${CYAN}      .--.  .-.     ${RESET}"
  say "${CYAN}   .-(    )(   )-.  ${RESET}  ${BOLD}cloudseed${RESET} ${DIM}v${VERSION}${RESET}"
  say "${CYAN}  (___.____)___.__) ${RESET}  ${DIM}${os} · ${arch} · GPU: ${gpu}${RESET}"
  say "${BLUE}      '  ' ${GREEN}\\,/${BLUE} '    ${RESET}  ${DIM}user: ${TARGET_USER} (${TARGET_HOME})${RESET}"
  say "${GREEN}           |       ${RESET}"
  say "${DIM}  ~~~~~~~~~~~~~~~~~~ ${RESET}"
  say ""
}

usage() {
  cat <<EOF
cloudseed v${VERSION} — one command to make a blank Ubuntu cloud VM feel like home.

Usage:
  install.sh                       interactive menu (needs a terminal)
  install.sh [steps] [options]     run exactly the given steps, no menu
  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash -s -- [flags]

Steps:
  --all                 run every step below
  --update              apt-get update
  --upgrade             apt-get upgrade (non-interactive, keeps existing configs)
  --git                 install git (offers to set user.name/email when interactive)
  --tools               apt CLI tools (see TOOLS_PACKAGES at the top of the script)
  --uv                  uv + Python ${PYTHON_VERSION} as the default python
  --helpers             copy contents/ to ~/shell-helpers and wire ~/.bashrc / ~/.zshrc
  --vim                 vim + dotfiles/vimrc as ~/.vimrc + vim-plug plugins
  --nvim                latest stable Neovim + ${NVIM_CONFIG_URL#https://github.com/}

Options:
  --nvim-sync           also run a headless Lazy plugin sync (implies --nvim; slow)
  --python <ver>        Python version for the uv step (default: 3.12)
  --ref <branch/tag>    cloudseed ref to fetch contents/ from when piped (default: main)
  -y, --yes             non-interactive; accept defaults (no flags + --yes = default steps)
  --dry-run             print what would happen, change nothing
  --uninstall           remove the rc blocks and ~/shell-helpers (packages and nvim stay)
  -h, --help            show this help

Log: ~/.cloudseed/install.log
EOF
}

# Run "$@" with output going to the log, showing a spinner on a TTY.
spin() {
  local label=$1
  shift
  log "+ $*"
  if [ "$DRY_RUN" = 1 ]; then would "$*"; return 0; fi
  if [ ! -t 3 ] || [ -n "${CI:-}" ]; then
    "$@"
    return
  fi
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 pid rc=0 start=$SECONDS
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s %s(%s)%s' "$CYAN" "${frames:i++%10:1}" "$RESET" "$label" "$DIM" "$(fmt_dur $((SECONDS - start)))" "$RESET" >&3
    sleep 0.1
  done
  wait "$pid" || rc=$?
  printf '\r\e[K' >&3
  if [ "$rc" -ne 0 ]; then
    printf '  %s✗%s %s (exit %s)\n' "$RED" "$RESET" "$label" "$rc" >&3
  fi
  return "$rc"
}

# Prompt helpers — always talk to /dev/tty, never stdin (stdin is the script
# itself under `curl | bash`).
ask() { # ask "question" default -> echoes answer
  local reply
  printf '%s%s%s %s[%s]%s ' "$BOLD" "$1" "$RESET" "$DIM" "$2" "$RESET" >/dev/tty
  IFS= read -r reply </dev/tty || reply=""
  printf '%s' "${reply:-$2}"
}

ask_yn() { # ask_yn "question" y|n
  local hint="y/N" reply
  [ "$2" = y ] && hint="Y/n"
  printf '%s%s%s %s[%s]%s ' "$BOLD" "$1" "$RESET" "$DIM" "$hint" "$RESET" >/dev/tty
  IFS= read -r reply </dev/tty || reply=""
  reply="${reply:-$2}"
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ============================================================ environment ==

os_pretty() {
  if [ -r /etc/os-release ]; then
    (. /etc/os-release && printf '%s' "${PRETTY_NAME:-$ID}")
  else
    uname -s
  fi
}

os_id() { [ -r /etc/os-release ] && (. /etc/os-release && printf '%s' "${ID:-}") || true; }

gpu_name() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo "nvidia (unknown)"
  else
    echo "none"
  fi
}

detect_user() {
  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  else
    TARGET_USER="$(id -un)"
    TARGET_HOME="$HOME"
  fi
  TARGET_GROUP="$(id -gn "$TARGET_USER")"
}

# Run as the target user (matters when invoked via sudo).
as_user() {
  if [ "$EUID" -eq 0 ] && [ "$TARGET_USER" != root ]; then
    sudo -u "$TARGET_USER" -H env "PATH=$TARGET_HOME/.local/bin:$PATH" "$@"
  else
    env "HOME=$TARGET_HOME" "PATH=$TARGET_HOME/.local/bin:$PATH" "$@"
  fi
}

as_root() {
  if [ "$EUID" -eq 0 ]; then "$@"; else sudo -n "$@"; fi
}

# Dry-run aware wrappers.
run() {
  log "+ $*"
  if [ "$DRY_RUN" = 1 ]; then would "$*"; return 0; fi
  "$@"
}
run_user() { run as_user "$@"; }

# chown things we create in $TARGET_HOME when running as root for someone else.
fix_owner() {
  [ "$DRY_RUN" = 1 ] && return 0
  if [ "$EUID" -eq 0 ] && [ "$TARGET_USER" != root ]; then
    chown -R "$TARGET_USER:$TARGET_GROUP" "$@"
  fi
}

ensure_dir() { # create a dir owned by the target user
  [ -d "$1" ] && return 0
  run mkdir -p "$1"
  fix_owner "$1"
}

fetch() { # fetch URL OUTFILE
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"
  else
    wget -q --tries=3 -O "$2" "$1"
  fi
}

fetch_stdout() { # fetch URL -> stdout
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 "$1"
  else
    wget -q --tries=3 -O - "$1"
  fi
}

check_os() {
  local id
  id="$(os_id)"
  if [ "$id" = ubuntu ]; then
    case "$(. /etc/os-release && echo "$VERSION_ID")" in
      22.04 | 24.04) ;;
      *) warn "untested Ubuntu release: $(os_pretty) (tested: 22.04, 24.04)" ;;
    esac
    return 0
  fi
  warn "this doesn't look like Ubuntu ($(os_pretty)). cloudseed targets Ubuntu 22.04/24.04."
  if [ "$INTERACTIVE" = 1 ] && ask_yn "Continue anyway?" n; then return 0; fi
  [ "$DRY_RUN" = 1 ] && { warn "continuing because --dry-run changes nothing"; return 0; }
  die "aborting (non-Ubuntu system)"
}

# Root is needed for apt steps. Prime sudo once, up front, so the spinner never
# sits on a hidden password prompt.
ensure_root() {
  local s need=0
  for s in "${STEPS[@]}"; do
    if [ "${SELECTED[$s]:-0}" = 1 ] && [ "${STEP_NEEDS_ROOT[$s]:-0}" = 1 ]; then need=1; fi
  done
  [ "$need" = 1 ] || return 0
  if [ "$EUID" -eq 0 ]; then HAVE_ROOT=1; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then HAVE_ROOT=1; return 0; fi
  if ! command -v sudo >/dev/null 2>&1; then
    warn "not root and sudo is missing — apt steps will be skipped"
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    HAVE_ROOT=1
  elif [ "$CAN_PROMPT" = 1 ]; then
    say "${DIM}sudo is needed for apt steps:${RESET}"
    # shellcheck disable=SC2024  # sudo reads the password from the tty itself
    if sudo -v </dev/tty; then HAVE_ROOT=1; fi
  fi
  if [ "$HAVE_ROOT" = 1 ]; then
    # Keep the sudo timestamp fresh during long runs.
    (while sleep 60; do sudo -n true 2>/dev/null || exit; done) &
    SUDO_KEEPALIVE_PID=$!
  else
    warn "couldn't get sudo — apt steps will be skipped"
  fi
}

cleanup() {
  [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  return 0
}

on_main_err() {
  local rc=$? line=$1
  printf '%s✗ cloudseed: unexpected error at line %s (exit %s)%s\n' "$RED" "$line" "$rc" "$RESET" >&3
  [ -n "$LOG" ] && printf '  log: %s\n' "$LOG" >&3
}

on_step_err() {
  local rc=$? line=$1 cmd=$2
  echo "[error] step '${CURRENT_STEP}' failed at line ${line}: ${cmd} (exit ${rc})"
  printf '  %s✗ line %s:%s %s %s(exit %s)%s\n' "$RED" "$line" "$RESET" "$cmd" "$DIM" "$rc" "$RESET" >&3
}

# ================================================================= apt ====

apt_ensure_lists() {
  # A fresh container has no package lists; installing would just fail.
  if ! compgen -G '/var/lib/apt/lists/*_Packages*' >/dev/null; then
    info "no apt package lists yet — running apt-get update first"
    spin "apt-get update" as_root apt-get update
  fi
}

apt_install() {
  local pkg missing=()
  for pkg in "$@"; do
    if [ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)" != "install ok installed" ]; then
      missing+=("$pkg")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    info "already installed: $*"
    return 0
  fi
  apt_ensure_lists
  spin "apt-get install ${missing[*]}" as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get install -y "${missing[@]}"
}

# ================================================================= steps ==

step_update() {
  spin "apt-get update" as_root apt-get update
}

step_upgrade() {
  apt_ensure_lists
  spin "apt-get upgrade" as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get upgrade -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
}

step_git() {
  apt_install git
  info "$(git --version 2>/dev/null || echo 'git (dry-run)')"
  local name email
  name="$(as_user git config --global user.name 2>/dev/null || true)"
  if [ -n "$name" ]; then
    info "git identity: $name <$(as_user git config --global user.email 2>/dev/null || true)>"
  elif [ "$INTERACTIVE" = 1 ] && [ "$DRY_RUN" = 0 ]; then
    if ask_yn "  git user.name is unset. Set name/email now?" y; then
      name="$(ask "    name:" "$TARGET_USER")"
      email="$(ask "    email:" "")"
      run_user git config --global user.name "$name"
      [ -n "$email" ] && run_user git config --global user.email "$email"
      info "git identity set: $name <$email>"
    fi
  else
    info "git user.name is unset (set it with: git config --global user.name \"…\")"
  fi
}

step_tools() {
  apt_install "${TOOLS_PACKAGES[@]}"
  # Ubuntu ships fd as `fdfind`; expose it as `fd`.
  if command -v fdfind >/dev/null 2>&1 || [ "$DRY_RUN" = 1 ]; then
    local link="$TARGET_HOME/.local/bin/fd" target
    target="$(command -v fdfind || echo /usr/bin/fdfind)"
    if [ "$(readlink "$link" 2>/dev/null || true)" = "$target" ]; then
      info "fd → fdfind symlink already present"
    else
      ensure_dir "$TARGET_HOME/.local/bin"
      run_user ln -sfn "$target" "$link"
      [ "$DRY_RUN" = 1 ] || info "linked $link → $target"
    fi
  fi
}

step_uv() {
  local bindir="$TARGET_HOME/.local/bin" ver="$PYTHON_VERSION"
  ensure_dir "$bindir"
  if [ -x "$bindir/uv" ]; then
    info "uv already installed ($(as_user uv --version))"
  else
    run fetch https://astral.sh/uv/install.sh "$WORK_DIR/uv-install.sh"
    run chmod 644 "$WORK_DIR/uv-install.sh"
    spin "installing uv" as_user env UV_NO_MODIFY_PATH=1 "UV_INSTALL_DIR=$bindir" \
      sh "$WORK_DIR/uv-install.sh"
    [ "$DRY_RUN" = 1 ] || info "installed $(as_user uv --version)"
  fi

  local marker="$TARGET_HOME/.cloudseed/uv-python" via=""
  if [ "$DRY_RUN" = 1 ]; then
    would "uv python install $ver --default  (or set UV_PYTHON=$ver if unsupported)"
    return 0
  fi
  local help
  help="$(as_user uv python install --help 2>/dev/null || true)"
  if [[ "$help" == *--default* ]]; then
    if spin "uv python install $ver --default" as_user uv python install "$ver" --default; then
      via="--default"
    elif spin "uv python install $ver --default (preview)" as_user uv python install --preview "$ver" --default; then
      via="--default (preview)"
    fi
  fi
  if [ -n "$via" ]; then
    rm -f "$marker"
    info "Python $ver installed and set as default via $via ($(as_user python --version 2>&1 || true))"
  else
    spin "uv python install $ver" as_user uv python install "$ver"
    ensure_dir "$TARGET_HOME/.cloudseed"
    printf '%s\n' "$ver" >"$marker"
    fix_owner "$marker"
    info "this uv has no usable --default; pinned UV_PYTHON=$ver via ~/.cloudseed/uv-python (read by python.sh)"
  fi
}

# Locate the cloudseed source tree (contents/, dotfiles/): the directory next to
# the script (local checkout), or the $REF tarball from GitHub codeload,
# downloaded once per run. Prints the directory.
resolve_src() {
  if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/contents" ]; then
    if [ "$REF_SET" = 1 ]; then info "local checkout found; ignoring --ref $REF"; fi
    printf '%s' "$SCRIPT_DIR"
    return 0
  fi
  local url="https://codeload.github.com/${REPO}/tar.gz/${REF}" dir="$WORK_DIR/src"
  if [ -d "$dir/contents" ]; then printf '%s' "$dir"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then
    would "download $url and extract it"
    printf '%s' "$dir"
    return 0
  fi
  mkdir -p "$dir"
  log "+ fetch $url"
  fetch_stdout "$url" | tar -xz -C "$dir" --strip-components=1
  [ -d "$dir/contents" ] || { echo "no contents/ in $REPO@$REF" >&2; return 1; }
  printf '%s' "$dir"
}

# Rewrite an rc file with our block in place (or appended), printing to stdout.
render_rc_with_block() {
  awk -v s="$BLOCK_START" -v e="$BLOCK_END" -v body="$BLOCK_BODY" '
    $0 == s { if (!done) { print s; print body; print e } ; inblk = 1; done = 1; next }
    inblk   { if ($0 == e) inblk = 0; next }
            { print }
    END     { if (!done) { print ""; print s; print body; print e } }
  ' "$1"
}

# Same, with the block (and the blank line we put before it) removed.
render_rc_without_block() {
  awk -v s="$BLOCK_START" -v e="$BLOCK_END" '
    $0 == s { inblk = 1; held = 0; next }
    inblk   { if ($0 == e) inblk = 0; next }
            { if (held) print ""; held = 0; if ($0 == "") { held = 1; next } ; print }
    END     { if (held) print "" }
  ' "$1"
}

wire_rc() {
  local rc=$1 tmp
  local short="${rc/#"$TARGET_HOME"/\~}"
  if [ ! -e "$rc" ]; then
    run touch "$rc"
    fix_owner "$rc"
    [ "$DRY_RUN" = 1 ] && { would "add cloudseed block to $short"; return 0; }
  fi
  tmp="$WORK_DIR/rc.$$"
  render_rc_with_block "$rc" >"$tmp"
  if cmp -s "$tmp" "$rc"; then
    info "$short already wired"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    would "update cloudseed block in $short"
    return 0
  fi
  if [ ! -e "$rc.cloudseed.bak" ]; then
    cp -p "$rc" "$rc.cloudseed.bak"
    fix_owner "$rc.cloudseed.bak"
    info "backed up $short → $short.cloudseed.bak"
  fi
  # Write through the existing file so symlinks/permissions survive.
  cat "$tmp" >"$rc"
  info "wired $short"
}

rc_files() { # rc files we manage
  printf '%s\n' "$TARGET_HOME/.bashrc"
  if [ -e "$TARGET_HOME/.zshrc" ] || command -v zsh >/dev/null 2>&1; then
    printf '%s\n' "$TARGET_HOME/.zshrc"
  fi
}

step_helpers() {
  local src dest="$TARGET_HOME/shell-helpers" n rc
  src="$(resolve_src)/contents"
  ensure_dir "$dest"
  run cp -R "$src/." "$dest/"
  fix_owner "$dest"
  if [ "$DRY_RUN" = 0 ]; then
    n="$(find "$dest" -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')"
    info "copied contents/ → ~/shell-helpers ($n *.sh files auto-loaded)"
  fi
  while IFS= read -r rc; do wire_rc "$rc"; done < <(rc_files)
}

step_vim() {
  local src vimrc="$TARGET_HOME/.vimrc" plug="$TARGET_HOME/.vim/autoload/plug.vim"
  apt_install vim
  src="$(resolve_src)/dotfiles/vimrc"
  if [ -f "$vimrc" ] && cmp -s "$src" "$vimrc"; then
    info "already up to date: ~/.vimrc"
  else
    if [ -e "$vimrc" ]; then
      run mv "$vimrc" "$vimrc.bak.$TS"
      [ "$DRY_RUN" = 1 ] || info "backed up ~/.vimrc → ~/.vimrc.bak.$TS"
    fi
    run cp "$src" "$vimrc"
    fix_owner "$vimrc"
    [ "$DRY_RUN" = 1 ] || info "installed ~/.vimrc"
  fi
  if [ -s "$plug" ]; then
    info "vim-plug already installed"
  else
    ensure_dir "$TARGET_HOME/.vim"
    ensure_dir "$TARGET_HOME/.vim/autoload"
    run_user curl -fsSLo "$plug" https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    [ "$DRY_RUN" = 1 ] || info "installed vim-plug"
  fi
  # PlugInstall only fetches plugins that are missing, so re-runs are cheap.
  # vim -Es can exit non-zero on harmless startup messages; judge by the result.
  spin "vim +PlugInstall" as_user vim -E -s -u "$vimrc" -i NONE "+PlugInstall --sync" +qa || true
  if [ "$DRY_RUN" = 0 ]; then
    [ -d "$TARGET_HOME/.vim/plugged/vim-polyglot" ] || { echo "vim-polyglot wasn't installed" >&2; return 1; }
    info "vim plugins installed (vim-polyglot)"
  fi
}

nvim_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo x86_64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) return 1 ;;
  esac
}

# Prints "<tag> <url>" for the latest stable Neovim tarball for this arch,
# chosen from the GitHub releases API (asset names have changed before).
nvim_latest() {
  local arch=$1 json tag url name
  json="$(fetch_stdout https://api.github.com/repos/neovim/neovim/releases/latest)" || return 1
  tag="$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | sed -n '1s/.*"\([^"]*\)"$/\1/p')"
  for name in "nvim-linux-${arch}.tar.gz" "nvim-linux${arch/x86_/}.tar.gz"; do
    url="$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*"' \
      | sed 's/.*"\([^"]*\)"$/\1/' | grep -m1 "/${name//./\\.}\$" || true)"
    [ -n "$url" ] && break
  done
  [ -n "$tag" ] && [ -n "$url" ] || return 1
  printf '%s %s\n' "$tag" "$url"
}

install_neovim() {
  local arch opt="$TARGET_HOME/.local/opt/nvim" bindir="$TARGET_HOME/.local/bin" latest tag url have=""
  arch="$(nvim_arch)" || { echo "unsupported architecture: $(uname -m)" >&2; return 1; }
  [ -r "$opt/.cloudseed-tag" ] && have="$(cat "$opt/.cloudseed-tag")"

  if [ "$DRY_RUN" = 1 ] && ! command -v curl >/dev/null 2>&1; then
    would "download the latest nvim-linux-${arch}.tar.gz → $opt, symlink $bindir/nvim"
    return 0
  fi

  if latest="$(nvim_latest "$arch")"; then
    tag="${latest%% *}" url="${latest#* }"
  else
    # API unreachable or rate-limited (common on shared CI/cloud IPs): read the
    # tag from the releases/latest redirect, which isn't rate-limited.
    tag="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/neovim/neovim/releases/latest 2>/dev/null \
      | sed -n 's|.*/releases/tag/\(v[0-9][^/]*\)$|\1|p' || true)"
    if [ -n "$tag" ]; then
      info "releases API unavailable; latest tag $tag via redirect"
      url="https://github.com/neovim/neovim/releases/download/${tag}/nvim-linux-${arch}.tar.gz"
    elif [ -x "$opt/bin/nvim" ]; then
      warn "couldn't reach GitHub; keeping installed Neovim ${have:-}"
      tag="$have"
    else
      echo "couldn't determine the latest Neovim release" >&2
      return 1
    fi
  fi

  if [ -n "$have" ] && [ "$have" = "$tag" ] && [ -x "$opt/bin/nvim" ]; then
    info "Neovim $have already installed"
  else
    info "installing Neovim $tag (${url##*/})"
    if [ "$DRY_RUN" = 1 ]; then
      would "download $url → $opt, symlink $bindir/nvim"
    else
      fetch "$url" "$WORK_DIR/nvim.tar.gz"
      rm -rf "$WORK_DIR/nvim" && mkdir -p "$WORK_DIR/nvim"
      tar -xzf "$WORK_DIR/nvim.tar.gz" -C "$WORK_DIR/nvim" --strip-components=1
      "$WORK_DIR/nvim/bin/nvim" --version >/dev/null
      printf '%s\n' "$tag" >"$WORK_DIR/nvim/.cloudseed-tag"
      ensure_dir "$TARGET_HOME/.local/opt"
      rm -rf "$opt"
      mv "$WORK_DIR/nvim" "$opt"
      fix_owner "$opt"
    fi
  fi
  ensure_dir "$bindir"
  if [ "$(readlink "$bindir/nvim" 2>/dev/null || true)" != "$opt/bin/nvim" ]; then
    run_user ln -sfn "$opt/bin/nvim" "$bindir/nvim"
  fi
  [ "$DRY_RUN" = 1 ] || info "$("$bindir/nvim" --version | head -n1)"
}

# nvim-treesitter's `main` branch (used by AstroNvim v6) compiles parsers with
# the tree-sitter CLI, which apt doesn't ship in a new-enough version.
# Best effort: a failure here only warns.
install_tree_sitter_cli() {
  local arch bin="$TARGET_HOME/.local/bin/tree-sitter"
  if [ -x "$bin" ] && "$bin" --version >/dev/null 2>&1; then
    info "tree-sitter CLI already installed ($("$bin" --version))"
    return 0
  fi
  case "$(nvim_arch)" in x86_64) arch=x64 ;; *) arch=arm64 ;; esac
  local url="https://github.com/tree-sitter/tree-sitter/releases/latest/download/tree-sitter-linux-${arch}.gz"
  if [ "$DRY_RUN" = 1 ]; then would "download $url → $bin"; return 0; fi
  if fetch "$url" "$WORK_DIR/ts.gz" && gzip -dc "$WORK_DIR/ts.gz" >"$WORK_DIR/tree-sitter" \
    && chmod 755 "$WORK_DIR/tree-sitter" && "$WORK_DIR/tree-sitter" --version >/dev/null 2>&1; then
    mv "$WORK_DIR/tree-sitter" "$bin"
    fix_owner "$bin"
    info "installed $("$bin" --version)"
  else
    warn "prebuilt tree-sitter CLI doesn't run here ($(getconf GNU_LIBC_VERSION 2>/dev/null || echo 'unknown libc'); it needs a newer glibc)."
    warn "nvim still works, but nvim-treesitter can't compile extra parsers; Neovim's bundled ones still work"
  fi
}

install_nvim_config() {
  local cfg="$TARGET_HOME/.config/nvim" origin="" d
  if [ -d "$cfg/.git" ]; then
    origin="$(as_user git -C "$cfg" remote get-url origin 2>/dev/null || true)"
  fi
  if [[ "$origin" == *deependujha/nvim-config* ]]; then
    spin "git pull nvim-config" as_user git -C "$cfg" pull --ff-only
    info "nvim-config updated ($(as_user git -C "$cfg" rev-parse --short HEAD))"
    return 0
  fi
  for d in "$TARGET_HOME/.config/nvim" "$TARGET_HOME/.local/share/nvim" \
    "$TARGET_HOME/.local/state/nvim" "$TARGET_HOME/.cache/nvim"; do
    if [ -e "$d" ] || [ -L "$d" ]; then
      run mv "$d" "$d.bak.$TS"
      [ "$DRY_RUN" = 1 ] || info "backed up ${d/#"$TARGET_HOME"/\~} → ${d/#"$TARGET_HOME"/\~}.bak.$TS"
    fi
  done
  ensure_dir "$TARGET_HOME/.config"
  spin "git clone nvim-config" as_user git clone --depth 1 "$NVIM_CONFIG_URL" "$cfg"
  [ "$DRY_RUN" = 1 ] || info "cloned nvim-config → ~/.config/nvim"
}

step_nvim() {
  # Config first: running the nvim binary creates ~/.local/state/nvim, which
  # would otherwise get "backed up" on a fresh install.
  install_nvim_config
  install_neovim
  install_tree_sitter_cli
  if [ "$NVIM_SYNC" = 1 ]; then
    spin "nvim --headless +Lazy! sync (slow)" as_user timeout 1200 \
      "$TARGET_HOME/.local/bin/nvim" --headless "+Lazy! sync" +qa
    [ "$DRY_RUN" = 1 ] || info "plugins synced"
  else
    info "plugins will install on first launch (or rerun with --nvim-sync)"
  fi
}

# ============================================================== runner ====

# Why a step can't run right now (empty = it can).
skip_reason() {
  local step=$1 cmd missing=() providers=() p
  if [ "${STEP_NEEDS_ROOT[$step]:-0}" = 1 ] && [ "$HAVE_ROOT" = 0 ]; then
    echo "needs root or sudo"
    return
  fi
  for cmd in ${STEP_REQUIRES[$step]:-}; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [ "${#missing[@]}" -eq 0 ] && return
  # In dry-run, a selected providing step would have installed them.
  for cmd in "${missing[@]}"; do
    p="${CMD_PROVIDER[$cmd]:-}"
    if [ "$DRY_RUN" = 1 ] && [ "${SELECTED[$p]:-0}" = 1 ]; then continue; fi
    if [ "${RESULT[$p]:-}" = failed ]; then
      echo "$p failed (needed for: ${missing[*]})"
      return
    fi
    providers+=("--$p")
  done
  [ "${#providers[@]}" -eq 0 ] && return
  echo "missing ${missing[*]} — run with $(printf '%s\n' "${providers[@]}" | sort -u | tr '\n' ' ')first"
}

run_step() {
  local step=$1 start rc reason
  say "${BOLD}${BLUE}▸${RESET} ${BOLD}${step}${RESET}${DIM}…${RESET}"
  reason="$(skip_reason "$step")"
  if [ -n "$reason" ]; then
    RESULT[$step]=skipped REASON[$step]="$reason" DURATION[$step]=0
    say "${YELLOW}–${RESET} skipped ${DIM}(${reason})${RESET}"
    printf '\n=== %s: skipped (%s)\n' "$step" "$reason" >>"$LOG"
    return 0
  fi
  printf '\n=== %s (%s)\n' "$step" "$(date '+%F %T')" >>"$LOG"
  start=$SECONDS
  # Run in a subshell with errexit on, outside any conditional context (where
  # bash would silently ignore -e), so one failing step can't abort the rest.
  trap - ERR
  set +e
  (
    CURRENT_STEP=$step
    trap 'on_step_err "$LINENO" "$BASH_COMMAND"' ERR
    set -e
    "step_$step"
  ) </dev/null >>"$LOG" 2>&1
  rc=$?
  set -e
  trap 'on_main_err "$LINENO"' ERR
  DURATION[$step]=$((SECONDS - start))
  if [ "$rc" -eq 0 ]; then
    RESULT[$step]="done"
    say "${GREEN}✓${RESET} done ${DIM}($(fmt_dur "${DURATION[$step]}"))${RESET}"
  else
    RESULT[$step]=failed
    say "${RED}✗ failed${RESET} ${DIM}($(fmt_dur "${DURATION[$step]}"))${RESET} — last 20 log lines:"
    tail -n 20 "$LOG" | sed "s/^/    ${DIM}│${RESET} /" >&3
    say "    ${DIM}full log: ${LOG}${RESET}"
  fi
}

summary() {
  local step status sym color failed=0 detail dur
  say ""
  say "${BOLD}  step      status    time${RESET}"
  for step in "${STEPS[@]}"; do
    detail="" dur=""
    [ -n "${DURATION[$step]:-}" ] && dur="$(fmt_dur "${DURATION[$step]}")"
    case "${RESULT[$step]:-unselected}" in
      done) sym="✓" color=$GREEN status="done" ;;
      failed) sym="✗" color=$RED status=failed failed=1 ;;
      skipped) sym="–" color=$YELLOW status=skipped detail="${REASON[$step]}" ;;
      *) sym="·" color=$DIM status="off" detail="not selected" ;;
    esac
    printf '  %-9s %s%s%s %-7s %-6s %s%s%s\n' "$step" "$color" "$sym" "$RESET" "$status" \
      "$dur" "$DIM" "$detail" "$RESET" >&3
  done
  say ""
  if [ "$DRY_RUN" = 1 ]; then
    say "${MAGENTA}dry run — nothing was changed.${RESET}"
  else
    say "${DIM}log: ${LOG}${RESET}"
  fi
  if [ "$failed" = 1 ]; then
    say "${RED}${BOLD}Some steps failed.${RESET} Fix the issue and re-run — finished steps are no-ops."
    return 1
  fi
  if [ "${SELECTED[helpers]:-0}" = 1 ] || [ "${SELECTED[uv]:-0}" = 1 ] || [ "${SELECTED[nvim]:-0}" = 1 ]; then
    say "${GREEN}${BOLD}All set.${RESET} Load your helpers with: ${BOLD}exec \$SHELL${RESET}"
  else
    say "${GREEN}${BOLD}All set.${RESET}"
  fi
}

# Checklist menu: toggle by number, Enter to run. Pure bash + ANSI.
menu() {
  local i s line tok drawn=0 n=${#STEPS[@]} mark toks
  local redraw=0
  [ -n "$RESET" ] && redraw=1
  for s in "${STEPS[@]}"; do SELECTED[$s]=${STEP_DEFAULT[$s]}; done
  while true; do
    if [ "$redraw" = 1 ] && [ "$drawn" -gt 0 ]; then
      printf '\e[%dA\e[J' "$drawn" >/dev/tty
    fi
    {
      printf '%sChoose what to run%s %s(toggle by number, then Enter)%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
      i=1
      for s in "${STEPS[@]}"; do
        if [ "${SELECTED[$s]}" = 1 ]; then mark="${GREEN}[x]${RESET}"; else mark="${DIM}[ ]${RESET}"; fi
        printf '  %s%d%s %s %-8s %s%s%s\n' "$CYAN" "$i" "$RESET" "$mark" "$s" "$DIM" "${STEP_DESC[$s]}" "$RESET"
        i=$((i + 1))
      done
      if [ "$NVIM_SYNC" = 1 ]; then mark="${GREEN}[x]${RESET}"; else mark="${DIM}[ ]${RESET}"; fi
      printf '  %s%d%s %s %-8s %s%s%s\n' "$CYAN" "$i" "$RESET" "$mark" "sync" "$DIM" "nvim: headless Lazy plugin sync (slow)" "$RESET"
      printf '  %sp%s     python   %s%s%s\n' "$CYAN" "$RESET" "$BOLD" "$PYTHON_VERSION" "$RESET"
      printf '  %sa%s all  %sn%s none  %sq%s quit  %s⏎%s run\n' "$CYAN" "$RESET" "$CYAN" "$RESET" "$CYAN" "$RESET" "$CYAN" "$RESET"
    } >/dev/tty
    drawn=$((n + 5))
    printf '%s›%s ' "$BOLD" "$RESET" >/dev/tty
    IFS= read -r line </dev/tty || line=q
    [ -z "$line" ] && break
    read -r -a toks <<<"${line//,/ }"
    for tok in "${toks[@]}"; do
      case "$tok" in
        q | Q) say "bye."; exit 0 ;;
        a | A) for s in "${STEPS[@]}"; do SELECTED[$s]=1; done ;;
        n | N) for s in "${STEPS[@]}"; do SELECTED[$s]=0; done; NVIM_SYNC=0 ;;
        p | P)
          PYTHON_VERSION="$(ask "  python version:" "$PYTHON_VERSION")"
          drawn=$((drawn + 1))
          ;;
        *[!0-9]*) ;;
        *)
          if [ "$tok" -ge 1 ] && [ "$tok" -le "$n" ]; then
            s="${STEPS[$((tok - 1))]}"
            SELECTED[$s]=$((1 - ${SELECTED[$s]}))
            if [ "$s" = nvim ] && [ "${SELECTED[$s]}" = 0 ]; then NVIM_SYNC=0; fi
          elif [ "$tok" -eq $((n + 1)) ]; then
            NVIM_SYNC=$((1 - NVIM_SYNC))
            if [ "$NVIM_SYNC" = 1 ]; then SELECTED[nvim]=1; fi
          fi
          ;;
      esac
    done
  done
  local chosen=()
  for s in "${STEPS[@]}"; do [ "${SELECTED[$s]}" = 1 ] && chosen+=("$s"); done
  if [ "$NVIM_SYNC" = 1 ]; then chosen+=("(+sync)"); fi
  if [ "${#chosen[@]}" -eq 0 ]; then say "nothing selected — bye."; exit 0; fi
  ask_yn "Run: ${chosen[*]}?" y || { say "bye."; exit 0; }
  say ""
}

uninstall() {
  local rc tmp short
  say "${BOLD}${BLUE}▸${RESET} ${BOLD}uninstall${RESET}${DIM}…${RESET}"
  while IFS= read -r rc; do
    short="${rc/#"$TARGET_HOME"/\~}"
    [ -f "$rc" ] || continue
    if ! grep -qxF "$BLOCK_START" "$rc"; then
      info "$short has no cloudseed block"
      continue
    fi
    if [ "$DRY_RUN" = 1 ]; then would "remove cloudseed block from $short"; continue; fi
    tmp="$WORK_DIR/rc.$$"
    render_rc_without_block "$rc" >"$tmp"
    cat "$tmp" >"$rc"
    info "removed cloudseed block from $short"
  done < <(printf '%s\n' "$TARGET_HOME/.bashrc" "$TARGET_HOME/.zshrc")
  if [ -d "$TARGET_HOME/shell-helpers" ]; then
    run rm -rf "$TARGET_HOME/shell-helpers"
    [ "$DRY_RUN" = 1 ] || info "removed \$HOME/shell-helpers"
  else
    info "\$HOME/shell-helpers not present"
  fi
  say "${GREEN}✓${RESET} done"
  say ""
  say "${DIM}Left alone on purpose: apt packages, uv + Python, Neovim (\$HOME/.local/opt/nvim,"
  say "\$HOME/.local/bin/nvim), \$HOME/.config/nvim, \$HOME/.vimrc + \$HOME/.vim, *.cloudseed.bak / *.bak.* backups, \$HOME/.cloudseed/.${RESET}"
  say "Open a new shell (or ${BOLD}exec \$SHELL${RESET}) to drop the loaded helpers."
}

parse_args() {
  local s
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) for s in "${STEPS[@]}"; do SELECTED[$s]=1; done; ANY_STEP_FLAG=1 ;;
      --update | --upgrade | --git | --uv | --tools | --helpers | --vim | --nvim)
        SELECTED[${1#--}]=1; ANY_STEP_FLAG=1 ;;
      --nvim-sync) NVIM_SYNC=1; SELECTED[nvim]=1; ANY_STEP_FLAG=1 ;;
      --python)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: --python needs a version" >&2; exit 2; }
        PYTHON_VERSION=$2; shift ;;
      --python=*) PYTHON_VERSION=${1#*=} ;;
      --ref)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: --ref needs a branch or tag" >&2; exit 2; }
        REF=$2; REF_SET=1; shift ;;
      --ref=*) REF=${1#*=}; REF_SET=1 ;;
      -y | --yes) YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --uninstall) UNINSTALL=1 ;;
      -h | --help) usage; exit 0 ;;
      *) echo "error: unknown option: $1" >&2; echo "run with --help for usage" >&2; exit 2 ;;
    esac
    shift
  done
  if [ "$UNINSTALL" = 1 ] && [ "$ANY_STEP_FLAG" = 1 ]; then
    echo "error: --uninstall can't be combined with step flags" >&2
    exit 2
  fi
}

main() {
  exec 3>&1
  parse_args "$@"
  setup_colors

  SCRIPT_DIR=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  if [ -t 1 ] && [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then CAN_PROMPT=1; fi
  [ "$CAN_PROMPT" = 1 ] && [ "$YES" = 0 ] && INTERACTIVE=1

  # Decide what to do before touching anything.
  if [ "$UNINSTALL" = 0 ] && [ "$ANY_STEP_FLAG" = 0 ] && [ "$INTERACTIVE" = 0 ]; then
    if [ "$YES" = 1 ]; then
      local s
      for s in "${STEPS[@]}"; do SELECTED[$s]=${STEP_DEFAULT[$s]}; done
    else
      usage >&2
      echo >&2
      echo "error: no steps given and no terminal to show the menu on (use --all, step flags, or --yes)" >&2
      exit 2
    fi
  fi

  detect_user
  WORK_DIR="$(mktemp -d)"
  chmod 755 "$WORK_DIR" # readable by $SUDO_USER when we drop privileges
  trap cleanup EXIT
  trap 'say ""; say "${RED}interrupted${RESET}"; exit 130' INT TERM
  trap 'on_main_err "$LINENO"' ERR

  if [ "$DRY_RUN" = 1 ]; then
    LOG="$WORK_DIR/install.log"
  else
    ensure_dir "$TARGET_HOME/.cloudseed"
    LOG="$TARGET_HOME/.cloudseed/install.log"
  fi
  {
    printf '\n##### cloudseed v%s — %s\n' "$VERSION" "$(date '+%F %T')"
    printf '# args: %s\n# user: %s (%s), euid %s, %s %s\n' "$*" "$TARGET_USER" "$TARGET_HOME" "$EUID" "$(os_pretty)" "$(uname -m)"
  } >>"$LOG"
  fix_owner "$LOG"

  banner
  check_os

  if [ "$UNINSTALL" = 1 ]; then
    uninstall
    exit 0
  fi

  if [ "$ANY_STEP_FLAG" = 0 ] && [ "$INTERACTIVE" = 1 ]; then menu; fi
  if [ "$DRY_RUN" = 1 ]; then
    say "${MAGENTA}${BOLD}dry run${RESET}${MAGENTA} — showing what would happen; nothing will change.${RESET}"
    say ""
  fi

  ensure_root
  local step
  for step in "${STEPS[@]}"; do
    if [ "${SELECTED[$step]:-0}" = 1 ]; then run_step "$step"; fi
  done

  if summary; then exit 0; else exit 1; fi
}

main "$@"
