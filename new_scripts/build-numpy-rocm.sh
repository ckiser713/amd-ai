#!/bin/bash
# NumPy 2.2.1 with ROCm-optimized BLAS (optional)
set -e
source env-gfx1151.sh

BUILD_DIR="$HOME/mpg-builds/numpy"
mkdir -p $BUILD_DIR && cd $BUILD_DIR

git clone --branch v2.2.1 https://github.com/numpy/numpy. git
cd numpy
git submodule update --init

# Use ROCm's BLAS
export NPY_BLAS_ORDER=rocblas
export NPY_LAPACK_ORDER=rocsolver
export BLAS=$ROCM_PATH/lib/librocblas.so
export LAPACK=$ROCM_PATH/lib/librocsolver.so

pip install .  --no-build-isolation

# Verify
python -c "
import numpy as np
np.show_config()
"

echo "=== NumPy (ROCm BLAS) build complete ==="