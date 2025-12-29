#!/bin/bash
# bitsandbytes 0.45.0 ROCm for gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env

source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"
source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

SRC_DIR="$ROOT_DIR/src/extras/bitsandbytes"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/bitsandbytes-*.whl 1> /dev/null 2>&1; then
    echo "✅ bitsandbytes already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building bitsandbytes 0.45.0 for ROCm"
echo "============================================"
parallel_env_summary

# ROCm fork
cd "$SRC_DIR"
rm -rf build dist

export BNB_ROCM_ARCH="gfx1151"
export ROCM_HOME=$ROCM_PATH
export HIP_PATH=$ROCM_PATH
export PYTORCH_ROCM_ARCH="gfx1151"

# Use Ninja for CMake builds
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

# Build wheel with parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation -v

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/bitsandbytes-*.whl

# Verify
python -c "
import bitsandbytes as bnb
print(f'bitsandbytes imported')
print(f'CUDA available: {bnb.cuda_setup.main.CUDASetup.get_instance().cuda_available}')
"

echo "=== bitsandbytes build complete ==="
