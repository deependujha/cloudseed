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
alias g='git'                    # git
alias gs='git status -sb'        # short status with branch
alias ga='git add'               # stage paths
alias gaa='git add --all'        # stage everything
alias gc='git commit'            # commit (opens editor)
alias gcm='git commit -m'        # commit with inline message: gcm "msg"
alias gca='git commit --amend'   # amend the last commit
alias gp='git push'              # push
alias gpf='git push --force-with-lease' # safe force-push
alias gpl='git pull --ff-only'   # pull, refuse to create merge commits
alias gf='git fetch --all --prune' # fetch every remote, drop stale branches
alias gd='git diff'              # unstaged changes
alias gds='git diff --staged'    # staged changes
alias gco='git checkout'         # checkout branch/paths
alias gsw='git switch'           # switch branch
alias gb='git branch'            # list branches
alias gst='git stash'            # stash changes
alias gstp='git stash pop'       # pop the latest stash
alias gl='git log --oneline --graph --decorate -20' # last 20 commits as a graph
alias gla='git log --oneline --graph --decorate --all' # every branch as a graph

# groot — cd to the root of the current git repo
groot() { cd "$(git rev-parse --show-toplevel)" || return; }
