#!/bin/bash
# ============================================
# FAISS 1.9.0 with ROCm GPU Support
# Benefit: GPU-accelerated vector similarity search
# ============================================
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"

FAISS_VERSION="1.9.0"
SRC_DIR="$ROOT_DIR/src/extras/faiss"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building FAISS $FAISS_VERSION for ROCm"
echo "============================================"

cd "$SRC_DIR"
rm -rf build

# Install build dependencies
pip install -q numpy swig

# Create build directory
mkdir -p build && cd build

# CMake configuration for ROCm
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DFAISS_ENABLE_GPU=ON \
    -DFAISS_ENABLE_ROCM=ON \
    -DCMAKE_HIP_ARCHITECTURES="gfx1151" \
    -DROCM_PATH="${ROCM_PATH}" \
    -DFAISS_ENABLE_PYTHON=ON \
    -DPython_EXECUTABLE=$(which python3.11) \
    -DBUILD_TESTING=OFF \
    -DFAISS_OPT_LEVEL=avx512 \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"

# Build
cmake --build . --parallel $(nproc)

# Build Python wheel
cd ../python
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR"

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/faiss*.whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
import faiss
print(f'FAISS loaded successfully')
ngpus = faiss.get_num_gpus()
print(f'Number of GPUs: {ngpus}')
"

echo ""
echo "=== FAISS build complete ==="
echo "Wheel: $ARTIFACTS_DIR/faiss*.whl"
