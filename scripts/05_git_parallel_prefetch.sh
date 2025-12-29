#!/usr/bin/env bash
set -euo pipefail

# Speed up git clone/fetch for repos with submodules by:
# - Enabling parallel submodule jobs
# - Fetching all remotes/tags recursively
# - Syncing and initializing submodules in parallel

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env
GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"

echo "Optimizing git clone/submodule throughput (jobs=$GIT_JOBS)..."

safe_git_cleanup() {
    local dir="$1"
    if [[ -d "$dir/.git" ]]; then
        # Remove stale lock files that might block git operations
        find "$dir/.git" -name "*.lock" -type f -delete 2>/dev/null || true
    fi
}


ensure_repo() {
    local target_dir="$1"
    local repo_url="$2"
    local branch="$3"
    local recursive="${4:-false}"

    if [[ ! -d "$target_dir" ]]; then
        echo ">>> Cloning $repo_url ($branch) to $target_dir..."
        if [[ "$recursive" == "true" ]]; then
            git clone --branch "$branch" --recursive "$repo_url" "$target_dir"
        else
            git clone --branch "$branch" "$repo_url" "$target_dir"
        fi
    else
        echo ">>> Updating $target_dir..."
        safe_git_cleanup "$target_dir"
        (
            cd "$target_dir"
            git fetch origin "$branch"
            git checkout "$branch"
            git pull origin "$branch"
        )
    fi
}

# Core Repos
repos=(
  "$ROOT_DIR/src/pytorch"
  "$ROOT_DIR/src/pytorch-cpu"
  "$ROOT_DIR/src/vllm"
  "$ROOT_DIR/src/llama.cpp"
)

# Extras Repos (Repo URL, Branch, Target Dir Name, Recursive)
# Format: "URL|BRANCH|DIR_NAME|RECURSIVE"
extras_repos=(
    "https://github.com/triton-lang/triton.git|v3.1.0|triton-rocm|false"
    "https://github.com/pytorch/vision.git|v0.20.1|torchvision|false"
    "https://github.com/pytorch/audio.git|v2.5.1|torchaudio|false"
    "https://github.com/numpy/numpy.git|v2.2.1|numpy|true"
    "https://github.com/ROCm/flash-attention.git|v2.7.4-cktile|flash-attention|false"
    "https://github.com/facebookresearch/xformers.git|v0.0.29|xformers|true"
    "https://github.com/ROCm/bitsandbytes.git|rocm_enabled|bitsandbytes|false"
    "https://github.com/microsoft/DeepSpeed.git|v0.16.2|deepspeed|false"
    "https://github.com/microsoft/onnxruntime.git|v1.20.1|onnxruntime|true"
    "https://github.com/cupy/cupy.git|v13.3.0|cupy|true"
    "https://github.com/facebookresearch/faiss.git|v1.9.0|faiss|false"
    "https://github.com/opencv/opencv.git|4.10.0|opencv|false"
    "https://github.com/opencv/opencv_contrib.git|4.10.0|opencv_contrib|false"
    "https://github.com/uploadcare/pillow-simd.git|10.4.0|pillow-simd|false"
    "https://github.com/ggml-org/llama.cpp.git|b7551|llama-cpp|false"
)

# Ensure extras repos exist
mkdir -p "$ROOT_DIR/src/extras"
for item in "${extras_repos[@]}"; do
    IFS='|' read -r url branch dirname recursive <<< "$item"
    ensure_repo "$ROOT_DIR/src/extras/$dirname" "$url" "$branch" "$recursive"
    repos+=("$ROOT_DIR/src/extras/$dirname")
done

# Parallel Optimization Loop
for repo in "${repos[@]}"; do
  if [[ ! -d "$repo/.git" ]]; then
    continue
  fi

  echo "Prefetching submodules/objects: $repo"
  safe_git_cleanup "$repo"
  (
    cd "$repo" || exit
    git config fetch.recurseSubmodules on-demand || true
    git config submodule.fetchJobs "$GIT_JOBS" || true
    
    # Only fetch if we can reach remote, otherwise skip to submodules
    if git remote get-url origin &>/dev/null; then
        git -c protocol.version=2 fetch --all --tags --recurse-submodules -j "$GIT_JOBS" --prune || echo "Fetch warning on $repo"
    fi

    if [[ -f ".gitmodules" ]]; then
        git submodule sync --recursive
        git -c submodule.fetchJobs="$GIT_JOBS" submodule update --init --recursive --jobs "$GIT_JOBS"
    fi
  )
done

echo "Done. Git repositories are synchronized."
