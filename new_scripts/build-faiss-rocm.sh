#!/bin/bash
# ============================================
# FAISS 1.9.0 with ROCm GPU Support
# Benefit: GPU-accelerated vector similarity search
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env-gfx1151.sh"

FAISS_VERSION="1.9.0"
BUILD_DIR="$HOME/mpg-builds/faiss"
WHEEL_DIR="$HOME/mpg-builds/wheels"

echo "============================================"
echo "Building FAISS $FAISS_VERSION for ROCm"
echo "============================================"

mkdir -p "$BUILD_DIR" "$WHEEL_DIR"
cd "$BUILD_DIR"

# Clean previous build
rm -rf faiss build

# Clone source
git clone --depth 1 --branch "v${FAISS_VERSION}" \
    https://github.com/facebookresearch/faiss. git
cd faiss

# Install build dependencies
pip install -q numpy swig

# Create build directory
mkdir -p build && cd build

# CMake configuration for ROCm
cmake ..  \
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
cd ../faiss/python
pip wheel . --no-deps --wheel-dir="$WHEEL_DIR"

# Install
pip install --force-reinstall "$WHEEL_DIR"/faiss*.whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
import faiss
print(f'FAISS loaded successfully')

# Check GPU
ngpus = faiss.get_num_gpus()
print(f'Number of GPUs: {ngpus}')

if ngpus > 0:
    # GPU test
    res = faiss.StandardGpuResources()
    d = 64
    nb = 10000
    nq = 100
    import numpy as np
    xb = np.random. random((nb, d)).astype('float32')
    xq = np.random.random((nq, d)).astype('float32')
    
    index_cpu = faiss.IndexFlatL2(d)
    index_gpu = faiss.index_cpu_to_gpu(res, 0, index_cpu)
    index_gpu.add(xb)
    
    import time
    start = time.time()
    D, I = index_gpu.search(xq, 10)
    elapsed = time.time() - start
    print(f'GPU search {nq} queries in {nb} vectors: {elapsed*1000:.2f}ms')
else:
    print('GPU not available, using CPU')
"

echo ""
echo "=== FAISS build complete ==="
echo "Wheel:  $WHEEL_DIR/faiss*.whl"