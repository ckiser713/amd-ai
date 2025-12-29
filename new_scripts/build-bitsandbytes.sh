#!/bin/bash
# bitsandbytes 0.45.0 ROCm for gfx1151
set -e
source env-gfx1151.sh

BUILD_DIR="$HOME/mpg-builds/bitsandbytes"
mkdir -p $BUILD_DIR && cd $BUILD_DIR

# ROCm fork
git clone --branch rocm_enabled https://github.com/ROCm/bitsandbytes. git
cd bitsandbytes

export BNB_ROCM_ARCH="gfx1151"
export ROCM_HOME=$ROCM_PATH
export HIP_PATH=$ROCM_PATH

# Build
pip install -e . --no-build-isolation

# Verify
python -c "
import bitsandbytes as bnb
print(f'bitsandbytes imported')
print(f'CUDA available: {bnb.cuda_setup. main. CUDASetup. get_instance().cuda_available}')
"

echo "=== bitsandbytes build complete ==="