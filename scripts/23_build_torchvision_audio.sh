#!/bin/bash
# torchvision 0.20.1 + torchaudio 2.5.1 for gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
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
    
    export FORCE_CUDA=1
    export USE_ROCM=1
    export TORCHVISION_USE_FFMPEG=1
    export TORCHVISION_USE_VIDEO_CODEC=1
    export PYTORCH_ROCM_ARCH="gfx1151"
    export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
    export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
    export MAX_JOBS="$MAX_JOBS"
    
    # Build wheel (FORCE_CUDA=1 enables CUDA API compat for ROCm)
    pip wheel . --no-deps --no-build-isolation --wheel-dir="$ARTIFACTS_DIR" -v
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
    
    # Use setup.py with explicit parallel flag (same as PyTorch build)
    python setup.py bdist_wheel -- "-j$MAX_JOBS"
    cp dist/torchaudio-2.5.1*.whl "$ARTIFACTS_DIR/"
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
