#!/bin/bash
# ============================================
# CuPy 13.3.0 with ROCm/HIP Backend
# Benefit: NumPy-compatible GPU arrays, CUDA code compatibility
# ============================================
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"

CUPY_VERSION="13.3.0"
SRC_DIR="$ROOT_DIR/src/extras/cupy"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building CuPy $CUPY_VERSION for ROCm"
echo "============================================"

cd "$SRC_DIR"
rm -rf build dist

# Install build dependencies
pip install -q cython fastrlock

# Set ROCm environment
export CUPY_INSTALL_USE_HIP=1
export ROCM_HOME="${ROCM_PATH}"
export HIP_HOME="${ROCM_PATH}"
export CUPY_HIPCC_GENERATE_CODE="--offload-arch=gfx1151"
export HCC_AMDGPU_TARGET="gfx1151"
export PYTORCH_ROCM_ARCH="gfx1151"

# hipBLAS, hipFFT, etc.
export CUPY_ROCM_USE_HIPBLAS=1
export CUPY_ROCM_USE_HIPFFT=1
export CUPY_ROCM_USE_HIPSPARSE=1
export CUPY_ROCM_USE_HIPRAND=1
export CUPY_ROCM_USE_RCCL=1
export CUPY_ROCM_USE_MIOPEN=0  # MIOpen may not support gfx1151 yet

# Build wheel
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" -vvv

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/cupy-*.whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
import cupy as cp
print(f'CuPy version: {cp.__version__}')
print(f'Device: {cp.cuda.Device().name}')
print(f'Compute Capability: {cp.cuda.Device().compute_capability}')
"

echo ""
echo "=== CuPy build complete ==="
echo "Wheel: $ARTIFACTS_DIR/cupy-*.whl"
