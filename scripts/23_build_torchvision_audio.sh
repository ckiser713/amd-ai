#!/bin/bash
# torchvision 0.20.1 + torchaudio 2.5.1 for gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load lock manager and check lock status
source "$SCRIPT_DIR/lock_manager.sh"
if ! check_lock "$0"; then
    echo "❌ Script is LOCKED. User permission required to execute/modify."
    echo "   Run: ./scripts/lock_manager.sh --unlock scripts/23_build_torchvision_audio.sh"
    exit 1
fi

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env
ensure_numpy_from_artifacts

source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"
source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

# Activate virtual environment (project-local, repo-relative)
VENV_DIR="${VENV_DIR:-"$ROOT_DIR/.venv"}"
if [[ -f "$VENV_DIR/bin/activate" ]]; then
    source "$VENV_DIR/bin/activate"
fi

SRC_VISION="$ROOT_DIR/src/extras/torchvision"
SRC_AUDIO="$ROOT_DIR/src/extras/torchaudio"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

# Source checks
if [[ ! -d "$SRC_VISION" ]]; then
    echo "Source not found in $SRC_VISION. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

if [[ ! -d "$SRC_AUDIO" ]]; then
    echo "Source not found in $SRC_AUDIO. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

# Ensure custom PyTorch is installed first
python -c "import torch; assert 'rocm' in torch.__version__.lower() or torch.version.hip"

echo "============================================"
echo "Checking TorchVision 0.20.1"
echo "============================================"

if ls "$ARTIFACTS_DIR"/torchvision-*.whl 1> /dev/null 2>&1; then
    echo "✅ TorchVision already exists, skipping build."
    pip install "$ARTIFACTS_DIR"/torchvision-*.whl --no-deps --force-reinstall
else
    echo "Building TorchVision..."
    parallel_env_summary
    
    cd "$SRC_VISION"
    rm -rf build dist
    
    # Disable LTO for TorchVision - causes multiple definition errors with vision.o/vision_hip.o
    # Both files define vision::cuda_version() and LTO merges them causing linker conflict
    export CFLAGS="${CFLAGS//-flto=auto/}"
    export CXXFLAGS="${CXXFLAGS//-flto=auto/}"
    export LDFLAGS="${LDFLAGS//-flto=auto/}"
    
    # Build wheel (ROCm build takes priority)
    pip wheel . --no-deps --no-build-isolation --wheel-dir="$ARTIFACTS_DIR" -v --no-index --find-links="$ARTIFACTS_DIR" --find-links="$ROOT_DIR/wheels/cache"
    pip install "$ARTIFACTS_DIR"/torchvision-0.20.1*.whl --force-reinstall --no-deps
fi

echo "============================================"
echo "Checking TorchAudio 2.5.1"
echo "============================================"

if ls "$ARTIFACTS_DIR"/torchaudio-*.whl 1> /dev/null 2>&1; then
    echo "✅ TorchAudio already exists, skipping build."
    pip install "$ARTIFACTS_DIR"/torchaudio-*.whl --no-deps --force-reinstall
else
    echo "Building TorchAudio..."
    parallel_env_summary
    
    cd "$SRC_AUDIO"
    rm -rf build dist
    
    export USE_ROCM=1
    export USE_CUDA=0
    export PYTORCH_ROCM_ARCH="gfx1151"
    export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
    export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
    
    # Use pip wheel for consistent build behavior and parallelization
    pip wheel . --no-deps --no-build-isolation --wheel-dir="$ARTIFACTS_DIR" -v --no-index --find-links="$ARTIFACTS_DIR" --find-links="$ROOT_DIR/wheels/cache"
    pip install "$ARTIFACTS_DIR"/torchaudio-2.5.1*.whl --force-reinstall --no-deps
fi

# Verify (change directory to avoid importing from source tree)
cd "$ROOT_DIR"
python -c "
import torch, torchvision, torchaudio
print(f'torch: {torch.__version__}')
print(f'torchvision: {torchvision.__version__}')
print(f'torchaudio: {torchaudio.__version__}')
"

echo "✅ TorchVision/TorchAudio build complete"

# Lock this script after successful build
lock_script "$0" "torchvision+torchaudio"
