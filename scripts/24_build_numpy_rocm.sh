#!/bin/bash
# NumPy 2.2.1 with ROCm-optimized BLAS (optional)
# Optimized for AMD Strix Halo 395+MAX 128GB
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load lock manager and check lock status
source "$SCRIPT_DIR/lock_manager.sh"
if ! check_lock "$0"; then
    echo "❌ Script is LOCKED. User permission required to execute/modify."
    echo "   Run: ./scripts/lock_manager.sh --unlock scripts/24_build_numpy_rocm.sh"
    exit 1
fi

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

SRC_DIR="$ROOT_DIR/src/extras/numpy"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/numpy-*.whl 1> /dev/null 2>&1; then
    echo "✅ NumPy already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building NumPy 2.2.1 with ROCm BLAS"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build dist

# Use ROCm's BLAS
export NPY_BLAS_ORDER=rocblas
export NPY_LAPACK_ORDER=rocsolver
# Ensure strict adherence to ROCM_PATH
export BLAS=$ROCM_PATH/lib/librocblas.so
export LAPACK=$ROCM_PATH/lib/librocsolver.so
export PYTORCH_ROCM_ARCH="gfx1151"

# NumPy parallel build
export NPY_NUM_BUILD_JOBS="$MAX_JOBS"

# Use meson's ninja backend
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

# Build wheel to artifacts with explicit parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation -v

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/numpy-*.whl

# Verify (change directory to avoid importing from source tree)
cd "$ROOT_DIR"
python -c "
import numpy as np
np.show_config()
"

echo "=== NumPy (ROCm BLAS) build complete ==="

# Lock this script after successful build
WHEEL_FILE=$(ls "$ARTIFACTS_DIR"/numpy-*.whl 2>/dev/null | head -1)
lock_script "$0" "$(basename "$WHEEL_FILE")"
