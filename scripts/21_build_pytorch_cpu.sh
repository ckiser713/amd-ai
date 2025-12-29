#!/usr/bin/env bash
set -euo pipefail

echo "🏗️  Building PyTorch 2.9.1 (CPU-only)..."

# Resolve repo root before changing directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source scripts/11_env_cpu_optimized.sh

# Idempotency check: Skip if any PyTorch wheel exists
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
if ls "$ARTIFACTS_DIR"/torch-*.whl 1> /dev/null 2>&1; then
    echo "✅ PyTorch already exists in artifacts/, skipping CPU build."
    exit 0
fi

# Configuration
PYTORCH_VERSION="2.9.1"
PYTORCH_SRC_DIR="${PYTORCH_SRC_DIR:-src/pytorch-cpu}"
BUILD_DIR="$PYTORCH_SRC_DIR/build"
NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
if [[ "${NUM_JOBS:-}" =~ ^[0-9]+$ && "${MAX_JOBS:-}" =~ ^[0-9]+$ && ${NUM_JOBS} -lt ${MAX_JOBS} ]]; then
    export MAX_JOBS="$NUM_JOBS"
fi
GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

configure_git_parallel() {
    git config fetch.recurseSubmodules on-demand || true
    git config submodule.fetchJobs "$GIT_JOBS" || true
}

git_fetch_all_recursive() {
    git -c protocol.version=2 fetch --all --tags --recurse-submodules -j "$GIT_JOBS" --prune
}

update_submodules_parallel() {
    git submodule sync --recursive
    git -c submodule.fetchJobs="$GIT_JOBS" submodule update --init --recursive --filter=blob:none --depth=1 --jobs "$GIT_JOBS"
}

# Clone PyTorch if not exists
if [[ ! -d "$PYTORCH_SRC_DIR" ]]; then
    echo "Cloning PyTorch v$PYTORCH_VERSION for CPU build (blobless partial clone)..."
    git clone --single-branch --branch "v$PYTORCH_VERSION" --depth=1 --filter=blob:none --recurse-submodules --shallow-submodules --jobs "$GIT_JOBS" https://github.com/pytorch/pytorch.git "$PYTORCH_SRC_DIR"
    cd "$PYTORCH_SRC_DIR"
    configure_git_parallel
    git_fetch_all_recursive
    git checkout "v$PYTORCH_VERSION"
    update_submodules_parallel
else
    cd "$PYTORCH_SRC_DIR"
    configure_git_parallel
    git_fetch_all_recursive
    git checkout "v$PYTORCH_VERSION" 2>/dev/null || echo "Using existing source"
    update_submodules_parallel
fi

# CPU-only build environment
export USE_ROCM=0
export USE_CUDA=0
export USE_DISTRIBUTED=1
export USE_NCCL=0
export USE_MKLDNN=1
export USE_MKLDNN_CBLAS=1
export USE_OPENMP=1
export BUILD_TEST=0
export MAX_JOBS="$NUM_JOBS"

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Building CPU-only PyTorch with architecture: $CPU_ARCH"
echo "Using $MAX_JOBS parallel jobs"
echo "CMake/Ninja parallel: $CMAKE_BUILD_PARALLEL_LEVEL ($NINJAFLAGS)"
echo "Git parallel jobs: $GIT_JOBS"

# Build with optimized parallelism
python setup.py clean

# Use ninja for faster builds if available
if command -v ninja &> /dev/null; then
    echo "Using ninja build system for optimal parallelism"
    export USE_NINJA=1
    export CMAKE_GENERATOR=Ninja
    python setup.py bdist_wheel --cmake
else
    # Aggressive make parallelism
    python setup.py bdist_wheel --cmake -- "-j$MAX_JOBS" "--output-sync=target"
fi

# Install the wheel
WHEEL_FILE=$(find dist -name "*.whl" | head -1)
if [[ -n "$WHEEL_FILE" ]]; then
    echo "Installing CPU-only PyTorch: $WHEEL_FILE"
    pip install "$WHEEL_FILE" --force-reinstall --no-deps
    
    # Save the wheel to wheels directory (repo-relative)
    mkdir -p "$ROOT_DIR/wheels"
    cp "$WHEEL_FILE" "$ROOT_DIR/wheels/"
    echo "Wheel saved to: $ROOT_DIR/wheels/$(basename \"$WHEEL_FILE\")"

    # Also copy wheel to top-level artifacts/ for easy discovery
    ARTIFACTS_DIR="$ROOT_DIR/artifacts"
    mkdir -p "$ARTIFACTS_DIR"
    cp "$WHEEL_FILE" "$ARTIFACTS_DIR/"
    echo "Wheel copied to: $ARTIFACTS_DIR/$(basename \"$WHEEL_FILE\")"
    
    # Verify
    python -c "
import torch
print(f'PyTorch CPU version: {torch.__version__}')
print(f'CUDA/ROCm available: {torch.cuda.is_available()}')
print(f'CPU Capabilities:')
print(f'  MKL available: {torch.backends.mkl.is_available()}')
print(f'  OpenMP threads: {torch.get_num_threads()}')
"
else
    echo "❌ No wheel file found"
    exit 1
fi

echo "✅ PyTorch $PYTORCH_VERSION (CPU-only) built successfully"
