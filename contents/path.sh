# shellcheck shell=bash
# cloudseed: PATH setup. Sourced by both bash and zsh.
# ~/.local/bin holds uv, nvim, fd and uv-managed python.

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH

# Default editor for git, crontab, etc. — only once nvim is actually installed.
if command -v nvim >/dev/null 2>&1; then
  export EDITOR=nvim VISUAL=nvim
fi
