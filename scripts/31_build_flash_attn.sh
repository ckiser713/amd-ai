#!/bin/bash
# Flash Attention 2.7.4 for ROCm gfx1151
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"
source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

SRC_DIR="$ROOT_DIR/src/extras/flash-attention"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building Flash Attention 2.7.4 for ROCm"
echo "============================================"

# Use ROCm-compatible fork
cd "$SRC_DIR"
rm -rf build dist

export GPU_ARCHS="gfx1151"
export PYTORCH_ROCM_ARCH="gfx1151"
export MAX_JOBS=$(nproc)

# Strix Halo: Enable all optimizations
export FLASH_ATTENTION_FORCE_BUILD=TRUE
export FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE

# Build wheel
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/flash_attn-*.whl

# Verify
python -c "
import flash_attn
print(f'Flash Attention: {flash_attn.__version__}')
from flash_attn import flash_attn_func
print('flash_attn_func imported successfully')
"

echo "=== Flash Attention build complete ==="
