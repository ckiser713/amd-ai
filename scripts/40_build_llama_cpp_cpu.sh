#!/usr/bin/env bash
set -euo pipefail

echo "🦙 Building llama.cpp (CPU-optimized)..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-"$ROOT_DIR/artifacts"}"
mkdir -p "$ARTIFACTS_DIR"

source scripts/11_env_cpu_optimized.sh
ensure_numpy_from_artifacts

if [[ -f "$ARTIFACTS_DIR/llama_cpp_cpu.tar.gz" ]]; then
    echo "✅ llama.cpp CPU already exists in artifacts/, skipping build."
    exit 0
fi

# Configuration
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-src/llama.cpp}"
# Ensure absolute path
if [[ "$LLAMA_CPP_DIR" != /* ]]; then
    LLAMA_CPP_DIR="$ROOT_DIR/$LLAMA_CPP_DIR"
fi
BUILD_DIR="$LLAMA_CPP_DIR/build/cpu"
NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
if [[ "${NUM_JOBS:-}" =~ ^[0-9]+$ && "${MAX_JOBS:-}" =~ ^[0-9]+$ && ${NUM_JOBS} -lt ${MAX_JOBS} ]]; then
    export MAX_JOBS="$NUM_JOBS"
fi
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

# Clone llama.cpp
if [[ ! -d "$LLAMA_CPP_DIR" ]]; then
    echo "Cloning llama.cpp (shallow)..."
    # Temporarily disable problematic git config
    git config --global --unset remote.origin.fetch 2>/dev/null || true
    git clone --depth=1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_CPP_DIR"
    cd "$LLAMA_CPP_DIR"
else
    cd "$LLAMA_CPP_DIR"
    # Keep shallow history to depth=1
    git fetch --depth=1 origin b7551
    git checkout b7551
    git reset --hard origin/b7551
fi

# Create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "Building with CPU architecture: $CPU_ARCH"
echo "Using $MAX_JOBS parallel jobs"
echo "CMake/Ninja parallel: $CMAKE_BUILD_PARALLEL_LEVEL ($NINJAFLAGS)"

# Configure with CMake - prefer ninja for faster builds
if command -v ninja &> /dev/null; then
    cmake "$LLAMA_CPP_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
        -GNinja \
        -DLLAMA_NATIVE=ON \
        -DLLAMA_AVX=ON \
        -DLLAMA_AVX2=ON \
        -DLLAMA_AVX512=ON \
        -DLLAMA_FMA=ON \
        -DLLAMA_F16C=ON \
        -DLLAMA_BLAS=ON \
        -DLLAMA_BLAS_VENDOR=OpenBLAS \
        -DLLAMA_METAL=OFF \
        -DLLAMA_CUDA=OFF \
        -DLLAMA_HIPBLAS=OFF \
        -DLLAMA_CLBLAST=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DLLAMA_CURL=ON \
        -DLLAMA_HTTP=ON \
        -DLLAMA_SERVER=ON
    
    # Build with ninja
    ninja $NINJAFLAGS
else
    cmake "$LLAMA_CPP_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DLLAMA_NATIVE=ON \
        -DLLAMA_AVX=ON \
        -DLLAMA_AVX2=ON \
        -DLLAMA_AVX512=ON \
        -DLLAMA_FMA=ON \
        -DLLAMA_F16C=ON \
        -DLLAMA_BLAS=ON \
        -DLLAMA_BLAS_VENDOR=OpenBLAS \
        -DLLAMA_METAL=OFF \
        -DLLAMA_CUDA=OFF \
        -DLLAMA_HIPBLAS=OFF \
        -DLLAMA_CLBLAST=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DLLAMA_CURL=ON \
        -DLLAMA_HTTP=ON \
        -DLLAMA_SERVER=ON
    
    # Build with make
    make -j$MAX_JOBS --output-sync=target
fi

# Verify builds
echo "Verifying builds..."
ls -la bin/ | grep -E "(llama|server)"

# Create symlinks to project root
cd ../..
ln -sf "$BUILD_DIR/bin/llama-cli" llama-cpu 2>/dev/null || true
ln -sf "$BUILD_DIR/bin/llama-server" llama-server-cpu 2>/dev/null || true

echo "✅ llama.cpp CPU build complete"
echo "   Binaries: $BUILD_DIR/bin/"
echo "   Main executable: $BUILD_DIR/bin/llama-cli"
echo "   Server: $BUILD_DIR/bin/llama-server"

# Package artifacts to $ARTIFACTS_DIR
ARTIFACT_TAR="$ARTIFACTS_DIR/llama_cpp_cpu.tar.gz"
echo "Packaging CPU build into $ARTIFACT_TAR"
tar -czf "$ARTIFACT_TAR" -C "$BUILD_DIR" .
echo "   Contents: $(tar -tzf "$ARTIFACT_TAR" | head -n 5)…"

# Save to RoCompNew
mkdir -p ../../../RoCompNew/llama_cpp/cpu
cp -r "$BUILD_DIR" ../../../RoCompNew/llama_cpp/cpu/
echo "llama.cpp CPU build saved to: ../../../RoCompNew/llama_cpp/cpu/$(basename "$BUILD_DIR")"
