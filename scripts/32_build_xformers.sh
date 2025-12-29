#!/bin/bash
# xformers 0.0.29 for ROCm gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env

source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"
source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

SRC_DIR="$ROOT_DIR/src/extras/xformers"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/xformers-*.whl 1> /dev/null 2>&1; then
    echo "✅ xformers already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building xFormers 0.0.29 for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build dist

export PYTORCH_ROCM_ARCH="gfx1151"
export FORCE_CUDA=0
# MAX_JOBS already set by parallel_env.sh with memory-aware calculation

# Use ninja for parallel CMake builds
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

# Build wheel with parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation -v

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/xformers-*.whl

# Verify
python -c "
import xformers
print(f'xformers: {xformers.__version__}')
from xformers.ops import memory_efficient_attention
print('memory_efficient_attention imported')
"

echo "=== xformers build complete ==="
