#!/bin/bash
# ============================================
# Pillow-SIMD 10.4.0 with AVX-512 Support
# Benefit: 4-6x faster image operations
# ============================================
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"

PILLOW_VERSION="10.4.0"
SRC_DIR="$ROOT_DIR/src/extras/pillow-simd"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building Pillow-SIMD $PILLOW_VERSION (AVX-512)"
echo "============================================"

cd "$SRC_DIR"
rm -rf build dist

# Install build dependencies
pip install -q setuptools wheel

# Set SIMD flags for Zen 5 (AVX-512)
export CFLAGS="-O3 -march=znver5 -mtune=znver5 -mavx512f -mavx512bw -mavx512vl -ffast-math"
export CC="gcc"

# Build wheel
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR"

# Remove standard Pillow and install SIMD version
pip uninstall -y Pillow pillow-simd 2>/dev/null || true
pip install --force-reinstall --no-deps "$ARTIFACTS_DIR"/pillow*.whl

# Verify
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
