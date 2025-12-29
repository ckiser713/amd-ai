#!/bin/bash
# llama.cpp b7551 + HIP for gfx1151
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"

SRC_DIR="$ROOT_DIR/src/extras/llama-cpp"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building llama.cpp (b7551) for ROCm"
echo "============================================"

cd "$SRC_DIR"
rm -rf build

# CMake configuration for gfx1151
cmake -B build \
    -DGGML_HIP=ON \
    -DAMDGPU_TARGETS="gfx1151" \
    -DGGML_HIP_UMA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=hipcc \
    -DCMAKE_CXX_COMPILER=hipcc \
    -DCMAKE_C_FLAGS="-O3 -march=znver5" \
    -DCMAKE_CXX_FLAGS="-O3 -march=znver5" \
    -DGGML_NATIVE=ON \
    -DGGML_LTO=ON \
    -DGGML_CUDA_F16=ON \
    -DGGML_CUDA_GRAPHS=ON \
    -DLLAMA_CURL=ON

# Build with all cores
cmake --build build --config Release -j$(nproc)

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
