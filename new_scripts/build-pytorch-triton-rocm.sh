#!/bin/bash
# ============================================
# PyTorch-Triton-ROCm 3.1.0
# Benefit:  Optimized Triton integration for PyTorch
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env-gfx1151.sh"

TRITON_VERSION="3.1.0"
BUILD_DIR="$HOME/mpg-builds/pytorch-triton-rocm"
WHEEL_DIR="$HOME/mpg-builds/wheels"

echo "============================================"
echo "Building PyTorch-Triton-ROCm $TRITON_VERSION"
echo "============================================"

mkdir -p "$BUILD_DIR" "$WHEEL_DIR"
cd "$BUILD_DIR"

# Clean previous build
rm -rf triton

# Clone ROCm-optimized fork
git clone --branch "release/${TRITON_VERSION}" \
    https://github.com/triton-lang/triton.git
cd triton

# Set environment
export TRITON_BUILD_WITH_CLANG_LLD=1
export TRITON_BUILD_PROTON=OFF
export TRITON_CODEGEN_AMD_HIP_BACKEND=1
export LLVM_SYSPATH=${ROCM_PATH}/llvm
export AMDGPU_TARGETS="gfx1151"

# Additional ROCm configuration
export TRITON_USE_ROCM=ON
export ROCM_PATH="${ROCM_PATH}"

# Install build dependencies
pip install -q cmake ninja pybind11

# Apply gfx1151 patches if needed
find . -name "*. py" -exec grep -l "gfx90" {} \; | while read f; do
    if !  grep -q "gfx1151" "$f"; then
        sed -i 's/\["gfx90a"\]/["gfx90a", "gfx1151"]/g' "$f"
        echo "Patched: $f"
    fi
done

# Build wheel
cd python
pip wheel . --no-deps --wheel-dir="$WHEEL_DIR" --no-build-isolation

# Install
pip install --force-reinstall "$WHEEL_DIR"/triton-*.whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
import triton
import triton.language as tl
print(f'Triton version: {triton.__version__}')

# Simple kernel test
@triton.jit
def add_kernel(x_ptr, y_ptr, output_ptr, n_elements, BLOCK_SIZE:  tl.constexpr):
    pid = tl.program_id(axis=0)
    block_start = pid * BLOCK_SIZE
    offsets = block_start + tl.arange(0, BLOCK_SIZE)
    mask = offsets < n_elements
    x = tl.load(x_ptr + offsets, mask=mask)
    y = tl.load(y_ptr + offsets, mask=mask)
    output = x + y
    tl.store(output_ptr + offsets, output, mask=mask)

import torch
size = 1024
x = torch. rand(size, device='cuda')
y = torch.rand(size, device='cuda')
output = torch.empty_like(x)

grid = lambda meta: (triton.cdiv(size, meta['BLOCK_SIZE']),)
add_kernel[grid](x, y, output, size, BLOCK_SIZE=256)
torch.cuda.synchronize()

print(f'Triton kernel test: OK')
print(f'Output sample: {output[:5]}')
"

echo ""
echo "=== PyTorch-Triton-ROCm build complete ==="
echo "Wheel: $WHEEL_DIR/triton-*.whl"