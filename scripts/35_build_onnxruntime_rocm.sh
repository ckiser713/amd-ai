#!/bin/bash
# ============================================
# ONNX Runtime 1.20.1 with ROCm Execution Provider
# Benefit: Fast ONNX model inference on gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
# ============================================
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env
ensure_numpy_from_artifacts

source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"
source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

# Activate virtual environment (project-local, repo-relative)
VENV_DIR="${VENV_DIR:-"$ROOT_DIR/.venv"}"
if [[ -f "$VENV_DIR/bin/activate" ]]; then
    source "$VENV_DIR/bin/activate"
fi

ORT_VERSION="1.20.1"
SRC_DIR="$ROOT_DIR/src/extras/onnxruntime"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/onnxruntime*.whl 1> /dev/null 2>&1; then
    echo "✅ ONNX Runtime already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building ONNX Runtime $ORT_VERSION for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build

# Install build dependencies
pip install -q cmake ninja packaging

export PYTORCH_ROCM_ARCH="gfx1151"
export ROCM_VERSION="7.1.1"

# Build with ROCm EP using memory-aware parallelism
./build.sh \
    --config Release \
    --build_shared_lib \
    --parallel "$MAX_JOBS" \
    --skip_tests \
    --use_rocm \
    --rocm_home "${ROCM_PATH}" \
    --rocm_version "${ROCM_VERSION}" \
    --build_wheel \
    --cmake_generator Ninja \
    --cmake_extra_defines \
        CMAKE_HIP_ARCHITECTURES="gfx1151" \
        onnxruntime_BUILD_UNIT_TESTS=OFF \
        CMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
        CMAKE_C_FLAGS="${CFLAGS}" \
        CMAKE_CXX_FLAGS="${CXXFLAGS}"

# Copy wheel
cp build/Linux/Release/dist/onnxruntime*.whl "$ARTIFACTS_DIR/"

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/onnxruntime*.whl

# Verify (change directory to avoid importing from source tree)
cd "$ROOT_DIR"
echo ""
echo "=== Verification ==="
python -c "
import onnxruntime as ort
print(f'ONNX Runtime version: {ort.__version__}')
print(f'Available providers: {ort.get_available_providers()}')
print(f'Device: {ort.get_device()}')

# Check ROCm EP
if 'ROCMExecutionProvider' in ort.get_available_providers():
    print('✅ ROCm Execution Provider available')
else:
    print('⚠️ ROCm EP not available, using CPU')
"

echo ""
echo "=== ONNX Runtime build complete ==="
echo "Wheel: $ARTIFACTS_DIR/onnxruntime*.whl"
