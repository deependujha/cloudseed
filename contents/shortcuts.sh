# shellcheck shell=bash
# cloudseed: general + git shortcuts. Sourced by both bash and zsh.
# Every alias is commented — delete or tweak freely.

# ---------------------------------------------------------------- navigation
alias ..='cd ..'                 # up one directory
alias ...='cd ../..'             # up two directories
alias ....='cd ../../..'         # up three directories
alias -- -='cd -'                # jump back to the previous directory

# ---------------------------------------------------------------- listing
alias ll='ls -alhF --color=auto' # long list, human sizes, hidden files
alias la='ls -A --color=auto'    # everything except . and ..
alias l='ls -CF --color=auto'    # compact columns
alias lt='ls -alhtr --color=auto' # long list, newest last
alias t2='tree -L 2 -C'          # tree, two levels deep
alias t3='tree -L 3 -C'          # tree, three levels deep

# ---------------------------------------------------------------- safety nets
alias cp='cp -i'                 # confirm before overwriting
alias mv='mv -i'                 # confirm before overwriting
alias mkdir='mkdir -p'           # create parent dirs as needed

# ---------------------------------------------------------------- misc
alias grep='grep --color=auto'   # coloured grep matches
alias h='history'                # shell history
alias c='clear'                  # clear the screen
alias path='echo "$PATH" | tr ":" "\n"' # one PATH entry per line
alias ports='ss -tulpn'          # listening TCP/UDP ports
alias df='df -h'                 # human-readable disk usage
alias du1='du -h --max-depth=1'  # size of each child of the current dir
alias myip='curl -fsS https://api.ipify.org; echo' # public IP of this VM
alias reload='exec "$SHELL" -l'  # restart the shell (picks up helper edits)

# mkcd DIR — create DIR and cd into it
mkcd() { mkdir -p -- "$1" && cd -- "$1" || return; }

# extract FILE — unpack most archive formats
extract() {
  case "$1" in
    *.tar.gz|*.tgz)   tar -xzf "$1" ;;
    *.tar.xz)         tar -xJf "$1" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$1" ;;
    *.tar)            tar -xf "$1" ;;
    *.zip)            unzip "$1" ;;
    *.gz)             gunzip "$1" ;;
    *) echo "extract: don't know how to unpack '$1'" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------- git
#!/bin/sh

# Git helper commands

alias gc='git add .; git commit'
alias gcu='git add .; git commit -m "update"'
alias gcp='git add .; git commit -m "update"; git push'
alias gcl='git diff'
alias gsync='git checkout main && (git remote | grep -q "^upstream$" && git pull upstream main || git pull origin main) && git push origin main'
alias gmsync="git checkout master && git pull upstream master && git push origin master"
alias gl='git log --oneline'
alias clean="yes '' | head -n 1000; clear && clear;"
alias act="source .venv/bin/activate"


# Git helper functions

# Check if a git repository is clean
is_git_clean() {
    [ -z "$(git status --porcelain)" ]
}

# Stash changes with a message
stash_changes() {
    git stash push -m "$1"
}

# Clone
clone() {
  local upstream_url="$1"

  if [ -z "$upstream_url" ]; then
    echo "Usage: clone <github-repo-url>"
    return 1
  fi

  # Extract repo name safely
  local repo_name
  repo_name=$(basename "$upstream_url" .git)

  # Your fork URL
  local fork_url="git@github.com:deependujha/${repo_name}.git"

  echo "Cloning fork: $fork_url"
  git clone "$fork_url" || return 1

  cd "$repo_name" || return 1

  echo "Adding upstream: $upstream_url"
  git remote add upstream "$upstream_url"

  echo
  git remote -v
}

# Pop the latest stash
pop_stash() {
    git stash pop
}

gpush () {
  local current_branch=$(git rev-parse --abbrev-ref HEAD)
  if [ -n "$current_branch" ]; then
    git push origin "$current_branch"
  else
    echo "Error: Could not determine the current branch name."
    return 1
  fi
}

gstatus () {
    git status
}

# Navigation
alias ..="cd .."
alias ...="cd ../.."

# Helpers
mkcd() {
  mkdir -p "$1" && cd "$1"
}

