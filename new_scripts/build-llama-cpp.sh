#!/bin/bash
# llama.cpp b7551 + HIP for gfx1151
set -e
source env-gfx1151.sh

BUILD_DIR="$HOME/mpg-builds/llama-cpp"
mkdir -p $BUILD_DIR && cd $BUILD_DIR

git clone --branch b7551 https://github.com/ggml-org/llama. cpp.git
cd llama.cpp

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

# Install binaries
sudo cp build/bin/* /usr/local/bin/
sudo cp build/lib/*.so /usr/local/lib/
sudo ldconfig

# Python bindings (optional)
pip install llama-cpp-python \
    --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/rocm \
    --force-reinstall --no-cache-dir \
    -C cmake. args="-DGGML_HIP=ON;-DAMDGPU_TARGETS=gfx1151;-DGGML_HIP_UMA=ON"

# Verify
llama-cli --version
python -c "from llama_cpp import Llama; print('llama-cpp-python OK')"

echo "=== llama.cpp build complete ==="