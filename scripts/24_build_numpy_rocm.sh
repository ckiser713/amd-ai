#!/bin/bash
# NumPy 2.2.1 with ROCm-optimized BLAS (optional)
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"

SRC_DIR="$ROOT_DIR/src/extras/numpy"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building NumPy 2.2.1 with ROCm BLAS"
echo "============================================"

cd "$SRC_DIR"
rm -rf build dist

# Use ROCm's BLAS
export NPY_BLAS_ORDER=rocblas
export NPY_LAPACK_ORDER=rocsolver
# Ensure strict adherence to ROCM_PATH
export BLAS=$ROCM_PATH/lib/librocblas.so
export LAPACK=$ROCM_PATH/lib/librocsolver.so
export PYTORCH_ROCM_ARCH="gfx1151"

# Build wheel to artifacts
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/numpy-*.whl

# Verify
python -c "
import numpy as np
np.show_config()
"

echo "=== NumPy (ROCm BLAS) build complete ==="
