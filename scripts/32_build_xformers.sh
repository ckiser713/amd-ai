#!/bin/bash
# xformers 0.0.29 for ROCm gfx1151
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"

SRC_DIR="$ROOT_DIR/src/extras/xformers"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building xFormers 0.0.29 for ROCm"
echo "============================================"

cd "$SRC_DIR"
rm -rf build dist

export PYTORCH_ROCM_ARCH="gfx1151"
export FORCE_CUDA=0
export MAX_JOBS=$(nproc)

# Build wheel
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation

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
