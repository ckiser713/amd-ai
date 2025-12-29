#!/bin/bash
# xformers 0.0.29 for ROCm gfx1151
set -e
source env-gfx1151.sh

BUILD_DIR="$HOME/mpg-builds/xformers"
mkdir -p $BUILD_DIR && cd $BUILD_DIR

git clone --branch v0.0.29 https://github.com/facebookresearch/xformers. git
cd xformers
git submodule update --init --recursive

export PYTORCH_ROCM_ARCH="gfx1151"
export FORCE_CUDA=0
export MAX_JOBS=$(nproc)

# Build
pip install -e . --no-build-isolation

# Verify
python -c "
import xformers
print(f'xformers:  {xformers.__version__}')
from xformers. ops import memory_efficient_attention
print('memory_efficient_attention imported')
"

echo "=== xformers build complete ==="