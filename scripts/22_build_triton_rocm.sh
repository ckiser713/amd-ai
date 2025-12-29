#!/bin/bash
# ============================================
# PyTorch-Triton-ROCm 3.1.0
# Benefit: Optimized Triton integration for PyTorch
# Optimized for AMD Strix Halo 395+MAX 128GB
# ============================================
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env

source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"
source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

TRITON_VERSION="3.1.0"
SRC_DIR="$ROOT_DIR/src/extras/triton-rocm"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/triton-*.whl 1> /dev/null 2>&1; then
    echo "✅ Triton already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building PyTorch-Triton-ROCm $TRITON_VERSION"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"

# Clean previous build artifacts inside source tree to ensure fresh build
rm -rf python/build python/dist

# Set environment
export TRITON_BUILD_WITH_CLANG_LLD=1
export TRITON_BUILD_PROTON=OFF
export TRITON_CODEGEN_AMD_HIP_BACKEND=1
# export LLVM_SYSPATH=${ROCM_PATH}/llvm
export AMDGPU_TARGETS="gfx1151"
export PYTORCH_ROCM_ARCH="gfx1151"
export TRITON_CODEGEN_BACKENDS="amd"

# Additional ROCm configuration
export TRITON_USE_ROCM=ON
export ROCM_PATH="${ROCM_PATH}"

# Triton parallelism - uses MAX_JOBS from parallel_env.sh
export TRITON_PARALLEL_LINK_JOBS="${TRITON_PARALLEL_LINK_JOBS:-$MAX_JOBS}"

# Use Ninja for CMake builds
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

# Install build dependencies
pip install -q cmake ninja pybind11

# Fix triton/profiler missing directory error (setup.py always expects it)
mkdir -p python/triton/profiler
touch python/triton/profiler/__init__.py

# Apply gfx1151 patches if needed (Idempotent patch)
find . -name "*.py" -exec grep -l "gfx90" {} \; | while read f; do
    if ! grep -q "gfx1151" "$f"; then
        sed -i 's/\["gfx90a"\]/["gfx90a", "gfx1151"]/g' "$f"
        echo "Patched: $f"
    fi
done

# Build wheel
cd python
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/triton-*.whl

# Verify
echo ""
echo "=== Verification ==="
cd /tmp && cd /tmp && cd /tmp && cd /tmp && python -c "
import triton
import triton.language as tl
print(f'Triton version: {triton.__version__}')
"

echo ""
echo "=== PyTorch-Triton-ROCm build complete ==="
echo "Wheel: $ARTIFACTS_DIR/triton-*.whl"
