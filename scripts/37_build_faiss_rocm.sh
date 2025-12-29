#!/bin/bash
# ============================================
# FAISS 1.9.0 with ROCm GPU Support
# Benefit: GPU-accelerated vector similarity search
# Optimized for AMD Strix Halo 395+MAX 128GB
# ============================================
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

FAISS_VERSION="1.9.0"
SRC_DIR="$ROOT_DIR/src/extras/faiss"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/faiss*.whl 1> /dev/null 2>&1; then
    echo "✅ FAISS already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building FAISS $FAISS_VERSION for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build

# Install build dependencies
pip install -q swig

# Create build directory
mkdir -p build && cd build

# CMake configuration for ROCm with Ninja for faster builds
cmake .. \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DFAISS_ENABLE_GPU=ON \
    -DFAISS_ENABLE_ROCM=ON \
    -DCMAKE_HIP_ARCHITECTURES="gfx1151" \
    -DROCM_PATH="${ROCM_PATH}" \
    -DFAISS_ENABLE_PYTHON=ON \
    -DPython_EXECUTABLE=$(which python3.11) \
    -DBUILD_TESTING=OFF \
    -DFAISS_OPT_LEVEL=avx512 \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"

# Build with memory-aware parallelism
cmake --build . --parallel "$MAX_JOBS"

# Build Python wheel
cd ../python
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR"

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/faiss*.whl

# Verify (change directory to avoid importing from source tree)
cd "$ROOT_DIR"
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
