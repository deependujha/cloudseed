# shellcheck shell=bash
# cloudseed: CUDA / NVIDIA helpers. Sourced by both bash and zsh.
# No-ops silently on machines without an NVIDIA driver.

command -v nvidia-smi >/dev/null 2>&1 || return 0

# ---------------------------------------------------------------- toolkit paths
# Use CUDA_HOME if already set, otherwise the standard /usr/local/cuda symlink.
if [ -z "${CUDA_HOME:-}" ] && [ -d /usr/local/cuda ]; then
  CUDA_HOME=/usr/local/cuda
fi
if [ -n "${CUDA_HOME:-}" ]; then
  export CUDA_HOME
  case ":$PATH:" in
    *":$CUDA_HOME/bin:"*) ;;
    *) PATH="$CUDA_HOME/bin:$PATH" ;;
  esac
  if [ -d "$CUDA_HOME/lib64" ]; then
    case ":${LD_LIBRARY_PATH:-}:" in
      *":$CUDA_HOME/lib64:"*) ;;
      *) LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
    esac
    export LD_LIBRARY_PATH
  fi
  export PATH
fi

# ---------------------------------------------------------------- aliases
alias gpu='nvidia-smi'           # full GPU status
alias gpuw='watch -n 1 nvidia-smi' # live GPU status, refreshed every second
alias gpul='nvidia-smi -L'       # list GPUs with UUIDs
alias gputop='nvtop'             # interactive GPU monitor
alias gpumem='nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv' # memory + util per GPU
alias gpuprocs='nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv' # processes holding GPU memory
alias nvccv='nvcc --version'     # CUDA compiler version

# cuda_on 0,1 — restrict this shell to the given GPUs (no arg: show current)
cuda_on() {
  if [ -n "$1" ]; then
    export CUDA_VISIBLE_DEVICES="$1"
  fi
  echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<all>}"
}

# cuda_all — make every GPU visible again
cuda_all() { unset CUDA_VISIBLE_DEVICES; echo "CUDA_VISIBLE_DEVICES=<all>"; }

# torch_cuda — quick sanity check that PyTorch sees the GPUs
torch_cuda() {
  python -c 'import torch; print("cuda:", torch.cuda.is_available(), "| devices:", torch.cuda.device_count(), "| torch", torch.__version__)'
}
