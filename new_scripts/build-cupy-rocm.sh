#!/bin/bash
# ============================================
# CuPy 13.3.0 with ROCm/HIP Backend
# Benefit:  NumPy-compatible GPU arrays, CUDA code compatibility
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env-gfx1151.sh"

CUPY_VERSION="13.3.0"
BUILD_DIR="$HOME/mpg-builds/cupy"
WHEEL_DIR="$HOME/mpg-builds/wheels"

echo "============================================"
echo "Building CuPy $CUPY_VERSION for ROCm"
echo "============================================"

mkdir -p "$BUILD_DIR" "$WHEEL_DIR"
cd "$BUILD_DIR"

# Clean previous build
rm -rf cupy

# Clone source
git clone --depth 1 --branch "v${CUPY_VERSION}" --recursive \
    https://github.com/cupy/cupy.git
cd cupy

# Install build dependencies
pip install -q cython fastrlock

# Set ROCm environment
export CUPY_INSTALL_USE_HIP=1
export ROCM_HOME="${ROCM_PATH}"
export HIP_HOME="${ROCM_PATH}"
export CUPY_HIPCC_GENERATE_CODE="--offload-arch=gfx1151"
export HCC_AMDGPU_TARGET="gfx1151"

# hipBLAS, hipFFT, etc. 
export CUPY_ROCM_USE_HIPBLAS=1
export CUPY_ROCM_USE_HIPFFT=1
export CUPY_ROCM_USE_HIPSPARSE=1
export CUPY_ROCM_USE_HIPRAND=1
export CUPY_ROCM_USE_RCCL=1
export CUPY_ROCM_USE_MIOPEN=0  # MIOpen may not support gfx1151 yet

# Build wheel
pip wheel . --no-deps --wheel-dir="$WHEEL_DIR" -vvv

# Install
pip install --force-reinstall "$WHEEL_DIR"/cupy-*. whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
import cupy as cp
print(f'CuPy version: {cp.__version__}')
print(f'Device: {cp.cuda.Device().name}')
print(f'Compute Capability: {cp. cuda.Device().compute_capability}')
print()

# Quick test
a = cp.random.randn(1000, 1000, dtype=cp.float32)
b = cp. random.randn(1000, 1000, dtype=cp.float32)
c = cp.dot(a, b)
cp.cuda.Stream.null.synchronize()
print(f'Matrix multiply test: OK (shape={c.shape})')
"

echo ""
echo "=== CuPy build complete ==="
echo "Wheel: $WHEEL_DIR/cupy-*.whl"