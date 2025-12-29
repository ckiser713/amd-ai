#!/bin/bash
# llama.cpp b7551 + HIP for gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env

source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"
source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

SRC_DIR="$ROOT_DIR/src/extras/llama-cpp"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/llama_cpp_python-*.whl 1> /dev/null 2>&1; then
    echo "✅ llama.cpp-python already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building llama.cpp (b7551) for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build

# CMake configuration for gfx1151 with Ninja for faster builds
cmake -B build \
    -GNinja \
    -DGGML_HIP=ON \
    -DAMDGPU_TARGETS="gfx1151" \
    -DGGML_HIP_UMA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=hipcc \
    -DCMAKE_CXX_COMPILER=hipcc \
    -DCMAKE_C_FLAGS="-O3 -march=znver5 -flto=auto" \
    -DCMAKE_CXX_FLAGS="-O3 -march=znver5 -flto=auto" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DGGML_NATIVE=ON \
    -DGGML_LTO=ON \
    -DGGML_CUDA_F16=ON \
    -DGGML_CUDA_GRAPHS=ON \
    -DLLAMA_CURL=ON

# Build with memory-aware parallelism
cmake --build build --config Release -j"$MAX_JOBS"

# Install binaries to system
sudo cp build/bin/* /usr/local/bin/
sudo cp build/lib/*.so /usr/local/lib/
sudo ldconfig

# Build python wheel for bindings
export CMAKE_ARGS="-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 -DGGML_HIP_UMA=ON"
pip wheel llama-cpp-python \
    --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/rocm \
    --wheel-dir="$ARTIFACTS_DIR" \
    --no-build-isolation

# Install Python bindings
pip install --force-reinstall --no-cache-dir "$ARTIFACTS_DIR"/llama_cpp_python-*.whl

# Verify
echo ""
echo "=== Verification ==="
llama-cli --version
python -c "from llama_cpp import Llama; print('llama-cpp-python OK')"

echo "=== llama.cpp build complete ==="
echo "Wheel: $ARTIFACTS_DIR/llama_cpp_python-*.whl"
