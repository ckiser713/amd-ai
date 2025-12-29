#!/bin/bash
# Flash Attention 2.7. 4 for ROCm gfx1151
set -e
source env-gfx1151.sh

BUILD_DIR="$HOME/mpg-builds/flash-attention"
mkdir -p $BUILD_DIR && cd $BUILD_DIR

# Use ROCm-compatible fork
git clone --branch v2.7.4-rocm https://github.com/ROCm/flash-attention. git
cd flash-attention

export GPU_ARCHS="gfx1151"
export PYTORCH_ROCM_ARCH="gfx1151"
export MAX_JOBS=$(nproc)

# Strix Halo:  Enable all optimizations
export FLASH_ATTENTION_FORCE_BUILD=TRUE
export FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE

pip install -e .  --no-build-isolation

# Verify
python -c "
import flash_attn
print(f'Flash Attention:  {flash_attn.__version__}')
from flash_attn import flash_attn_func
print('flash_attn_func imported successfully')
"

echo "=== Flash Attention build complete ==="