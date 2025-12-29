#!/usr/bin/env bash
set -euo pipefail

echo "🦙 Building llama.cpp with ROCm/HIP support..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-"$ROOT_DIR/artifacts"}"
mkdir -p "$ARTIFACTS_DIR"

source scripts/10_env_rocm_gfx1151.sh
source scripts/11_env_cpu_optimized.sh
ensure_numpy_from_artifacts

if [[ -f "$ARTIFACTS_DIR/llama_cpp_rocm.tar.gz" ]]; then
    echo "✅ llama.cpp ROCm already exists in artifacts/, skipping build."
    exit 0
fi

# Check ROCm
if [[ ! -d "$ROCM_PATH" ]]; then
    echo "❌ ROCm not found at $ROCM_PATH"
    echo "   Install ROCm 7.1.1 first"
    exit 1
fi

# Configuration
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-src/llama.cpp}"
# Ensure absolute path
if [[ "$LLAMA_CPP_DIR" != /* ]]; then
    LLAMA_CPP_DIR="$ROOT_DIR/$LLAMA_CPP_DIR"
fi
BUILD_DIR="$LLAMA_CPP_DIR/build/rocm"
NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
if [[ "${NUM_JOBS:-}" =~ ^[0-9]+$ && "${MAX_JOBS:-}" =~ ^[0-9]+$ && ${NUM_JOBS} -lt ${MAX_JOBS} ]]; then
    export MAX_JOBS="$NUM_JOBS"
fi
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

# Clone if needed
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
    
    # Apply critical SIGSEGV fix patch (prevents null pointer crashes)
    PATCH_FILE="$ROOT_DIR/patches/llama_sigsegv_fix.patch"
    if [[ -f "$PATCH_FILE" ]]; then
        echo "📋 Applying SIGSEGV fix patch..."
        if ! git apply --check "$PATCH_FILE" 2>/dev/null; then
            echo "⚠️  Patch already applied or conflict detected, checking reverse..."
            if git apply --check --reverse "$PATCH_FILE" 2>/dev/null; then
                echo "✅ Patch already applied, continuing..."
            else
                echo "❌ FATAL: Cannot apply critical SIGSEGV fix patch!"
                echo "   See: COMPLETE_GUIDE.md for manual fix instructions"
                exit 1
            fi
        else
            git apply "$PATCH_FILE"
            echo "✅ SIGSEGV fix patch applied successfully"
        fi
    else
        echo "⚠️  WARNING: Patch file not found at $PATCH_FILE"
        echo "   Build may produce unstable binaries. See COMPLETE_GUIDE.md"
    fi
fi

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "Building for ROCm GPU: $ROCM_GFX_ARCH"
echo "Using $MAX_JOBS parallel jobs"
echo "CMake/Ninja parallel: $CMAKE_BUILD_PARALLEL_LEVEL ($NINJAFLAGS)"

# Configure with ROCm/HIP - prefer ninja for faster builds
if command -v ninja &> /dev/null; then
    cmake "$LLAMA_CPP_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
        -GNinja \
        -DGGML_HIP=ON \
        -DGGML_HIPBLAS=ON \
        -DLLAMA_HIPBLAS=ON \
        -DLLAMA_HIP_UMA=ON \
        -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
        -DAMDGPU_TARGETS="$ROCM_GFX_ARCH" \
        -DLLAMA_CUDA=OFF \
        -DLLAMA_METAL=OFF \
        -DLLAMA_BLAS=OFF \
        -DLLAMA_CURL=ON \
        -DLLAMA_HTTP=ON \
        -DLLAMA_SERVER=ON \
        -DBUILD_SHARED_LIBS=ON
    
    # Build with ninja
    ninja $NINJAFLAGS
else
    cmake "$LLAMA_CPP_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DGGML_HIP=ON \
        -DGGML_HIPBLAS=ON \
        -DLLAMA_HIPBLAS=ON \
        -DLLAMA_HIP_UMA=ON \
        -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
        -DAMDGPU_TARGETS="$ROCM_GFX_ARCH" \
        -DLLAMA_CUDA=OFF \
        -DLLAMA_METAL=OFF \
        -DLLAMA_BLAS=OFF \
        -DLLAMA_CURL=ON \
        -DLLAMA_HTTP=ON \
        -DLLAMA_SERVER=ON \
        -DBUILD_SHARED_LIBS=ON
    
    # Build with make
    make -j$MAX_JOBS --output-sync=target
fi

# Verify
echo "Verifying ROCm build..."
if [[ -f "bin/llama-cli" ]]; then
    echo "✅ ROCm build successful"
    ./bin/llama-cli --version || true
else
    echo "❌ Build failed - llama-cli binary not found"
    exit 1
fi

# Create symlinks
cd ../..
ln -sf "$BUILD_DIR/bin/llama-cli" llama-rocm 2>/dev/null || true
ln -sf "$BUILD_DIR/bin/llama-server" llama-server-rocm 2>/dev/null || true

echo "✅ llama.cpp ROCm build complete"
echo "   GPU Target: $ROCM_GFX_ARCH"
echo "   Binaries: $BUILD_DIR/bin/"
echo "   Use -ngl N to offload N layers to GPU"

# Package artifacts to $ARTIFACTS_DIR
ARTIFACT_TAR="$ARTIFACTS_DIR/llama_cpp_rocm.tar.gz"
echo "Packaging ROCm build into $ARTIFACT_TAR"
tar -czf "$ARTIFACT_TAR" -C "$BUILD_DIR" .
echo "   Contents: $(tar -tzf "$ARTIFACT_TAR" | head -n 5)…"

# Save to RoCompNew
mkdir -p ../../../RoCompNew/llama_cpp/rocm
cp -r "$BUILD_DIR" ../../../RoCompNew/llama_cpp/rocm/
echo "llama.cpp ROCm build saved to: ../../../RoCompNew/llama_cpp/rocm/$(basename "$BUILD_DIR")"
