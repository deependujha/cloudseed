# shellcheck shell=bash
# cloudseed: uv / Python helpers. Sourced by both bash and zsh.

# If this uv couldn't register a default Python (`uv python install --default`),
# the installer records the chosen version here and we pin uv to it instead.
if [ -r "$HOME/.cloudseed/uv-python" ]; then
  UV_PYTHON="$(cat "$HOME/.cloudseed/uv-python")"
  export UV_PYTHON
fi

# ---------------------------------------------------------------- aliases
alias uvr='uv run'               # run a command in the project env
alias uva='uv add'               # add a dependency
alias uvrm='uv remove'           # remove a dependency
alias uvs='uv sync'              # sync the env with the lockfile
alias uvl='uv lock'              # refresh the lockfile
alias uvp='uv pip'               # pip-compatible interface
alias uvt='uv tool run'          # run a tool ephemerally (like pipx run / uvx)
alias venv='uv venv'             # create .venv in the current dir
alias act='. .venv/bin/activate' # activate ./.venv
alias deact='deactivate'         # leave the active venv
alias py='python'                # python
alias ipy='uvx ipython'          # throwaway IPython, no install needed
