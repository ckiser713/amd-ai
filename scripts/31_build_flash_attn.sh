#!/bin/bash
# Flash Attention 2.7.4 for ROCm gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env

source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"
source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

# Activate virtual environment (project-local, repo-relative)
VENV_DIR="${VENV_DIR:-"$ROOT_DIR/.venv"}"
if [[ -f "$VENV_DIR/bin/activate" ]]; then
    source "$VENV_DIR/bin/activate"
fi

SRC_DIR="$ROOT_DIR/src/extras/flash-attention"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/flash_attn-*.whl 1> /dev/null 2>&1; then
    echo "✅ Flash Attention already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building Flash Attention 2.7.4 for ROCm"
echo "============================================"
parallel_env_summary

# Use ROCm-compatible fork
cd "$SRC_DIR"
rm -rf build dist

export GPU_ARCHS="gfx1151"
export PYTORCH_ROCM_ARCH="gfx1151"
# MAX_JOBS already set by parallel_env.sh with memory-aware calculation

# Strix Halo: Enable all optimizations
export FLASH_ATTENTION_FORCE_BUILD=TRUE
export FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE

# Use ninja for parallel CMake builds
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

# Build wheel with explicit parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation -v

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/flash_attn-*.whl

# Verify (change directory to avoid importing from source tree)
cd "$ROOT_DIR"
python -c "
import flash_attn
print(f'Flash Attention: {flash_attn.__version__}')
from flash_attn import flash_attn_func
print('flash_attn_func imported successfully')
"

echo "=== Flash Attention build complete ==="
