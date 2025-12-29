#!/bin/bash
# ============================================
# ONNX Runtime 1.20.1 with ROCm Execution Provider
# Benefit: Fast ONNX model inference on gfx1151
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env-gfx1151.sh"

ORT_VERSION="1.20.1"
BUILD_DIR="$HOME/mpg-builds/onnxruntime"
WHEEL_DIR="$HOME/mpg-builds/wheels"

echo "============================================"
echo "Building ONNX Runtime $ORT_VERSION for ROCm"
echo "============================================"

mkdir -p "$BUILD_DIR" "$WHEEL_DIR"
cd "$BUILD_DIR"

# Clean previous build
rm -rf onnxruntime

# Clone source
git clone --depth 1 --branch "v${ORT_VERSION}" --recursive \
    https://github.com/microsoft/onnxruntime.git
cd onnxruntime

# Install build dependencies
pip install -q cmake ninja numpy packaging

# Build with ROCm EP
./build.sh \
    --config Release \
    --build_shared_lib \
    --parallel $(nproc) \
    --skip_tests \
    --use_rocm \
    --rocm_home "${ROCM_PATH}" \
    --rocm_version "7.1.1" \
    --build_wheel \
    --cmake_extra_defines \
        CMAKE_HIP_ARCHITECTURES="gfx1151" \
        onnxruntime_BUILD_UNIT_TESTS=OFF \
        CMAKE_C_FLAGS="${CFLAGS}" \
        CMAKE_CXX_FLAGS="${CXXFLAGS}"

# Copy wheel
cp build/Linux/Release/dist/onnxruntime*. whl "$WHEEL_DIR/"

# Install
pip install --force-reinstall "$WHEEL_DIR"/onnxruntime*. whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
import onnxruntime as ort
print(f'ONNX Runtime version: {ort.__version__}')
print(f'Available providers: {ort. get_available_providers()}')
print(f'Device:  {ort.get_device()}')

# Check ROCm EP
if 'ROCMExecutionProvider' in ort.get_available_providers():
    print('✅ ROCm Execution Provider available')
else:
    print('⚠️  ROCm EP not available, using CPU')
"

echo ""
echo "=== ONNX Runtime build complete ==="
echo "Wheel: $WHEEL_DIR/onnxruntime*. whl"