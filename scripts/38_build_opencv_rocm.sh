#!/bin/bash
# ============================================
# OpenCV 4.10.0 with ROCm/HIP Support
# Benefit: GPU-accelerated computer vision
# Optimized for AMD Strix Halo 395+MAX 128GB
# ============================================
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

OPENCV_VERSION="4.10.0"
SRC_OPENCV="$ROOT_DIR/src/extras/opencv"
SRC_CONTRIB="$ROOT_DIR/src/extras/opencv_contrib"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/cv2*.so 1> /dev/null 2>&1 || ls "$ARTIFACTS_DIR"/opencv*.whl 1> /dev/null 2>&1; then
    echo "✅ OpenCV already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_OPENCV" ]]; then
    echo "Source not found in $SRC_OPENCV. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi
if [[ ! -d "$SRC_CONTRIB" ]]; then
    echo "Source not found in $SRC_CONTRIB. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building OpenCV $OPENCV_VERSION for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_OPENCV"
rm -rf build
mkdir -p build && cd build

# Install build dependencies
pip install -q numpy

# CMake configuration with Ninja for faster builds
cmake .. \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DOPENCV_EXTRA_MODULES_PATH="$SRC_CONTRIB/modules" \
    -DPYTHON3_EXECUTABLE=$(which python3.11) \
    -DPYTHON3_INCLUDE_DIR=$(python3.11 -c "import sysconfig; print(sysconfig.get_path('include'))") \
    -DPYTHON3_LIBRARY=$(python3.11 -c "import sysconfig; print(sysconfig.get_config_var('LIBDIR'))") \
    -DBUILD_opencv_python3=ON \
    -DBUILD_opencv_python2=OFF \
    -DWITH_OPENCL=ON \
    -DWITH_OPENCL_SVM=ON \
    -DOPENCL_INCLUDE_DIR=${ROCM_PATH}/include \
    -DOPENCL_LIBRARY=${ROCM_PATH}/lib/libOpenCL.so \
    -DWITH_HIP=ON \
    -DHIP_COMPILER=${ROCM_PATH}/bin/hipcc \
    -DHIP_PATH=${ROCM_PATH} \
    -DGPU_ARCHS="gfx1151" \
    -DWITH_FFMPEG=ON \
    -DWITH_GSTREAMER=ON \
    -DWITH_TBB=ON \
    -DWITH_OPENMP=ON \
    -DBUILD_TESTS=OFF \
    -DBUILD_PERF_TESTS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"

# Build with memory-aware parallelism
cmake --build . --parallel "$MAX_JOBS"

# Copy Python bindings
OPENCV_PYTHON_SO=$(find . -name "cv2*.so" | head -1)
if [ -n "$OPENCV_PYTHON_SO" ]; then
    cp "$OPENCV_PYTHON_SO" "$ARTIFACTS_DIR/"
    
    SITE_PACKAGES=$(python3.11 -c "import site; print(site.getsitepackages()[0])")
    mkdir -p "${SITE_PACKAGES}/cv2"
    cp "$OPENCV_PYTHON_SO" "${SITE_PACKAGES}/cv2/"
    touch "${SITE_PACKAGES}/cv2/__init__.py"
fi

# Verify
echo ""
echo "=== Verification ==="
python -c "
import cv2
print(f'OpenCV version: {cv2.__version__}')
"

echo ""
echo "=== OpenCV build complete ==="
echo "Artifact: $ARTIFACTS_DIR/cv2*.so"
