#!/usr/bin/env bash
set -euo pipefail

echo "🏗️  Building PyTorch 2.9.1 with ROCm support..."

# Load environments
source scripts/10_env_rocm_gfx1151.sh
source scripts/11_env_cpu_optimized.sh
source scripts/parallel_env.sh
apply_parallel_env
ensure_numpy_from_artifacts

# Resolve repo root before changing directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"

# Idempotency check
if ls "$ARTIFACTS_DIR"/torch-2.9.1*.whl 1> /dev/null 2>&1; then
    echo "✅ PyTorch already exists in artifacts/, skipping build."
    exit 0
fi

# Check ROCm installation
if [[ ! -d "$ROCM_PATH" ]]; then
    echo "❌ ROCm not found at $ROCM_PATH"
    echo "   Install ROCm 7.1.1 first or update ROCM_PATH"
    exit 1
fi

# Configuration
PYTORCH_VERSION="2.9.1"
PYTORCH_SRC_DIR="${PYTORCH_SRC_DIR:-src/pytorch}"
PYTORCH_BUILD_TYPE="Release"
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
    # Avoid fetching all tags to prevent upstream tag/branch name collisions on ciflow refs
    git -c protocol.version=2 fetch --all --no-tags --recurse-submodules -j "$GIT_JOBS" --prune
}

update_submodules_parallel() {
    git submodule sync --recursive
    git -c submodule.fetchJobs="$GIT_JOBS" submodule update --init --recursive --depth=1 --jobs "$GIT_JOBS"
}

# Clone PyTorch if not exists
if [[ ! -d "$PYTORCH_SRC_DIR" ]]; then
    echo "Cloning PyTorch v$PYTORCH_VERSION (shallow clone)..."
    # Temporarily disable problematic git config
    git config --global --unset remote.origin.fetch 2>/dev/null || true
    git clone --single-branch --branch "v$PYTORCH_VERSION" --depth=1 --recurse-submodules --shallow-submodules --jobs "$GIT_JOBS" https://github.com/pytorch/pytorch.git "$PYTORCH_SRC_DIR"
    cd "$PYTORCH_SRC_DIR"
    git config --unset remote.origin.fetch 2>/dev/null || true
    configure_git_parallel
    git_fetch_all_recursive
    update_submodules_parallel
else
    cd "$PYTORCH_SRC_DIR"
    configure_git_parallel
    git_fetch_all_recursive
    git checkout "v$PYTORCH_VERSION" 2>/dev/null || echo "Using existing source"
    update_submodules_parallel
fi

# Set build environment
export USE_ROCM=1
export USE_CUDA=0
export USE_DISTRIBUTED=1
export USE_HIP=1
export USE_RCCL=1
export USE_NCCL=1
export USE_SYSTEM_NCCL=1
export USE_GLOO=1
export BUILD_TEST=0
export USE_FBGEMM=0
export USE_MKLDNN=1
export USE_MKLDNN_CBLAS=1
export USE_NNPACK=0
export USE_QNNPACK=0
export USE_XNNPACK=0
export USE_PYTORCH_QNNPACK=0
export MAX_JOBS="$NUM_JOBS"
# Force the built wheel to use the pinned version string (avoid dev suffixes)
export PYTORCH_BUILD_VERSION="$PYTORCH_VERSION"
export PYTORCH_BUILD_NUMBER=0

# Activate virtual environment (project-local, repo-relative)
VENV_DIR="${VENV_DIR:-"$ROOT_DIR/.venv"}"

if [[ ! -d "$VENV_DIR" ]]; then
    echo "❌ Virtualenv not found at: $VENV_DIR"
    echo "   Run ./scripts/02_install_python_env.sh from the repo root first."
    exit 1
fi

# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

# Clean previous builds (aggressive clean to avoid CMake cache issues)
rm -rf "$BUILD_DIR"
rm -rf dist
rm -rf build/aotriton  # Clean aotriton cache to prevent path mismatch errors
rm -f CMakeCache.txt
rm -rf CMakeFiles
mkdir -p "$BUILD_DIR"
export CMAKE_FRESH=1

echo "Building PyTorch with ROCm arch: $PYTORCH_ROCM_ARCH"
echo "Build type: $PYTORCH_BUILD_TYPE"
echo "Using $MAX_JOBS parallel jobs"
echo "CMake/Ninja parallel: $CMAKE_BUILD_PARALLEL_LEVEL ($NINJAFLAGS)"
echo "Git parallel jobs: $GIT_JOBS"

# Build using setup.py (official PyTorch ROCm build method)
# python setup.py clean
# Ensure ROCm hipified sources are generated (required for ROCm builds)
if [[ ! -f "c10/hip/impl/hip_cmake_macros.h.in" ]]; then
    echo "Generating ROCm sources via tools/amd_build/build_amd.py..."
    python tools/amd_build/build_amd.py
fi

# Use ninja for faster builds if available
if command -v ninja &> /dev/null; then
    echo "Using ninja build system for optimal parallelism"
    export USE_NINJA=1
    export CMAKE_GENERATOR=Ninja
    # python setup.py bdist_wheel --cmake
else
    # Aggressive make parallelism
    # python setup.py bdist_wheel --cmake -- "-j$MAX_JOBS" "--output-sync=target"
    echo "Ninja not found, falling back to make"
fi

# Build the wheel (NINJAFLAGS already set by parallel_env.sh)
python setup.py bdist_wheel

# Find and install the built wheel
WHEEL_FILE=$(find dist -name "*.whl" | head -1)
if [[ -n "$WHEEL_FILE" ]]; then
    echo "Installing built wheel: $WHEEL_FILE"
    pip install "$WHEEL_FILE" --force-reinstall --no-deps
    
    # Save the wheel to repo-relative cache locations
    WHEELS_OUT_DIR="$ROOT_DIR/wheels"
    mkdir -p "$WHEELS_OUT_DIR"
    cp "$WHEEL_FILE" "$WHEELS_OUT_DIR/"
    echo "Wheel saved to: $WHEELS_OUT_DIR/$(basename "$WHEEL_FILE")"
    
    ROCOMP_OUT_DIR="$ROOT_DIR/RoCompNew/pytorch"
    mkdir -p "$ROCOMP_OUT_DIR"
    cp "$WHEEL_FILE" "$ROCOMP_OUT_DIR/"
    echo "Wheel saved to: $ROCOMP_OUT_DIR/$(basename "$WHEEL_FILE")"
    
    # Alternative: Use develop mode to avoid import issues
    # pip install -e . --no-build-isolation
    
    # Verify installation
    echo "Verifying PyTorch ROCm installation..."
    # Change to a temporary directory to avoid import conflicts with source
    VERIFY_DIR=$(mktemp -d)
    pushd "$VERIFY_DIR" > /dev/null
    python -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'ROCm available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU: {torch.cuda.get_device_name(0)}')
    print(f'GPU Arch: $PYTORCH_ROCM_ARCH')
"
    popd > /dev/null
    rm -rf "$VERIFY_DIR"
else
    echo "❌ No wheel file found in dist/"
    exit 1
fi

echo "✅ PyTorch $PYTORCH_VERSION with ROCm built successfully"
