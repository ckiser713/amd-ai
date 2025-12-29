#!/bin/bash
# torchvision 0.20.1 + torchaudio 2.5.1 for gfx1151
set -e
source env-gfx1151.sh

BUILD_DIR="$HOME/mpg-builds"

# Ensure custom PyTorch is installed first
python -c "import torch; assert 'rocm' in torch.__version__. lower() or torch.version.hip"

### TORCHVISION ###
cd $BUILD_DIR
git clone --branch v0.20.1 https://github.com/pytorch/vision.git torchvision
cd torchvision

export FORCE_CUDA=0
export TORCHVISION_USE_FFMPEG=1
export TORCHVISION_USE_VIDEO_CODEC=1

python setup.py bdist_wheel
pip install dist/torchvision-0.20.1*. whl

### TORCHAUDIO ###
cd $BUILD_DIR
git clone --branch v2.5.1 https://github.com/pytorch/audio.git torchaudio
cd torchaudio

export USE_ROCM=1
export USE_CUDA=0

python setup.py bdist_wheel
pip install dist/torchaudio-2.5.1*.whl

# Verify
python -c "
import torch, torchvision, torchaudio
print(f'torch: {torch.__version__}')
print(f'torchvision: {torchvision.__version__}')
print(f'torchaudio: {torchaudio.__version__}')
"