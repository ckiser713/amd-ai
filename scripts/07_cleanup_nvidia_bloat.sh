#!/usr/bin/env bash
# scripts/07_cleanup_nvidia_bloat.sh
# Purpose: The "Antigravity" Sweep - Remove redundant NVIDIA/CUDA bloat from the wheel cache.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WHEELS_CACHE="$ROOT_DIR/wheels/cache"

echo "=== Antigravity Sweep: Cleaning NVIDIA/CUDA Bloat ==="

if [[ ! -d "$WHEELS_CACHE" ]]; then
    echo "Wheel cache directory $WHEELS_CACHE does not exist. Nothing to clean."
    exit 0
fi

# Targeted keywords
KEYWORDS=("nvidia" "cuda" "cublas" "cudnn" "nccl" "triton")

echo ">>> Searching for bloat in $WHEELS_CACHE..."

for KEYWORD in "${KEYWORDS[@]}"; do
    echo "Checking for '*$KEYWORD*'..."
    echo "Checking for '*$KEYWORD*'..."
    # 1. Clean wheels in the main cache
    find "$WHEELS_CACHE" -maxdepth 1 -type f -iname "*$KEYWORD*" -delete
    
    # 2. Clean bloat inside triton_deps (like the nvidia/ folder)
    # We use -mindepth 1 to avoid deleting triton_deps itself if the keyword is 'triton'
    if [[ -d "$WHEELS_CACHE/triton_deps" ]]; then
        find "$WHEELS_CACHE/triton_deps" -mindepth 1 -iname "*$KEYWORD*" -exec rm -rf {} +
    fi
done

echo ">>> Final check for heavy NVIDIA folders..."
if [[ -d "$WHEELS_CACHE/triton_deps/nvidia" ]]; then
    echo "Deleting heavy NVIDIA dependency folder in triton_deps..."
    rm -rf "$WHEELS_CACHE/triton_deps/nvidia"
fi

echo "=== Antigravity Sweep Complete ==="
