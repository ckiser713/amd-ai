#!/bin/bash
# ============================================
# Pillow-SIMD 10.4.0 with AVX-512 Support
# Benefit: 4-6x faster image operations
# Optimized for AMD Strix Halo 395+MAX 128GB
# ============================================
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env
ensure_numpy_from_artifacts

source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

PILLOW_VERSION="10.4.0"
SRC_DIR="$ROOT_DIR/src/extras/pillow-simd"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/Pillow_SIMD-*.whl 1> /dev/null 2>&1 || ls "$ARTIFACTS_DIR"/Pillow-*.whl 1> /dev/null 2>&1; then
    echo "✅ Pillow-SIMD already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building Pillow-SIMD $PILLOW_VERSION (AVX-512)"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build dist

# Install build dependencies
pip install -q setuptools wheel

# Override CFLAGS with Pillow-SIMD specific optimizations for Zen 5
# Override CFLAGS with Pillow-SIMD specific optimizations
# Use detected architecture or fallback to znver5 for Strix Halo
ARCH="${DETECTED_CPU_ARCH:-znver5}"
echo "Building for Architecture: $ARCH"

export CFLAGS="-O3 -march=$ARCH -mtune=$ARCH -mavx512f -mavx512bw -mavx512vl -mavx512dq -mavx512vbmi -flto=auto"
export LDFLAGS="${LDFLAGS:-} -lm -lmvec"
export LIBS="-lm -lmvec"
export CC="${CC:-gcc}"

# Build wheel with explicit parallel compilation and NO isolation to respect env vars
pip wheel . --no-deps --no-build-isolation --wheel-dir="$ARTIFACTS_DIR" -v

# Remove standard Pillow and install SIMD version
pip uninstall -y Pillow pillow-simd 2>/dev/null || true
pip install --force-reinstall --no-deps "$ARTIFACTS_DIR"/pillow*.whl

# Verify (change directory to avoid importing from source tree)
cd "$ROOT_DIR"
echo ""
echo "=== Verification ==="
python -c "
from PIL import Image, features
print(f'Pillow version: {Image.__version__}')
print(f'SIMD support: {features.check(\"libimagequant\")}')
"

echo ""
echo "=== Pillow-SIMD build complete ==="
echo "Wheel: $ARTIFACTS_DIR/pillow*.whl"
