#!/usr/bin/env bash
set -euo pipefail

# Speed up git clone/fetch for repos with submodules by:
# - enabling parallel submodule jobs
# - fetching all remotes/tags recursively
# - syncing and initializing submodules in parallel

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env
GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"

echo "Optimizing git clone/submodule throughput (jobs=$GIT_JOBS)..."

repos=(
  "$ROOT_DIR/src/pytorch"
  "$ROOT_DIR/src/pytorch-cpu"
  "$ROOT_DIR/src/vllm"
  "$ROOT_DIR/src/llama.cpp"
)

for repo in "${repos[@]}"; do
  if [[ ! -d "$repo/.git" ]]; then
    echo "Skipping (not a git repo): $repo"
    continue
  fi

  echo "Prefetching: $repo"
  (
    cd "$repo"
    git config fetch.recurseSubmodules on-demand || true
    git config submodule.fetchJobs "$GIT_JOBS" || true
    git -c protocol.version=2 fetch --all --tags --recurse-submodules -j "$GIT_JOBS" --prune
    git submodule sync --recursive
    git -c submodule.fetchJobs="$GIT_JOBS" submodule update --init --recursive --jobs "$GIT_JOBS"
  )
done

echo "Done. Git fetch/submodule settings now favor parallelism."
