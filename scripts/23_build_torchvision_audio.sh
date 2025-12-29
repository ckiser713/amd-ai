#!/bin/bash
# torchvision 0.20.1 + torchaudio 2.5.1 for gfx1151
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"

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
echo "Building TorchVision 0.20.1"
echo "============================================"

### TORCHVISION ###
cd "$SRC_VISION"
rm -rf build dist

export FORCE_CUDA=0
export TORCHVISION_USE_FFMPEG=1
export TORCHVISION_USE_VIDEO_CODEC=1
export PYTORCH_ROCM_ARCH="gfx1151"

python setup.py bdist_wheel
cp dist/torchvision-0.20.1*.whl "$ARTIFACTS_DIR/"
pip install "$ARTIFACTS_DIR"/torchvision-0.20.1*.whl

echo "============================================"
echo "Building TorchAudio 2.5.1"
echo "============================================"

### TORCHAUDIO ###
cd "$SRC_AUDIO"
rm -rf build dist

export USE_ROCM=1
export USE_CUDA=0
export PYTORCH_ROCM_ARCH="gfx1151"

python setup.py bdist_wheel
cp dist/torchaudio-2.5.1*.whl "$ARTIFACTS_DIR/"
pip install "$ARTIFACTS_DIR"/torchaudio-2.5.1*.whl

# Verify
python -c "
import torch, torchvision, torchaudio
print(f'torch: {torch.__version__}')
print(f'torchvision: {torchvision.__version__}')
print(f'torchaudio: {torchaudio.__version__}')
"
