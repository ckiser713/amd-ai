#!/bin/bash
# ============================================
# OpenCV 4.10.0 with ROCm/HIP Support
# Benefit: GPU-accelerated computer vision
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env-gfx1151.sh"

OPENCV_VERSION="4.10.0"
BUILD_DIR="$HOME/mpg-builds/opencv"
WHEEL_DIR="$HOME/mpg-builds/wheels"

echo "============================================"
echo "Building OpenCV $OPENCV_VERSION for ROCm"
echo "============================================"

mkdir -p "$BUILD_DIR" "$WHEEL_DIR"
cd "$BUILD_DIR"

# Clean previous build
rm -rf opencv opencv_contrib build

# Clone OpenCV and contrib modules
git clone --depth 1 --branch "${OPENCV_VERSION}" \
    https://github.com/opencv/opencv.git
git clone --depth 1 --branch "${OPENCV_VERSION}" \
    https://github.com/opencv/opencv_contrib. git

mkdir -p build && cd build

# Install build dependencies
pip install -q numpy

# CMake configuration
cmake ../opencv \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DOPENCV_EXTRA_MODULES_PATH=../opencv_contrib/modules \
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
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"

# Build
cmake --build . --parallel $(nproc)

# Copy Python bindings
OPENCV_PYTHON_SO=$(find .  -name "cv2*. so" | head -1)
if [ -n "$OPENCV_PYTHON_SO" ]; then
    SITE_PACKAGES=$(python3.11 -c "import site; print(site. getsitepackages()[0])")
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
print(f'Build info: ')
print(cv2.getBuildInformation()[: 500])

# Check OpenCL
if cv2.ocl. haveOpenCL():
    cv2.ocl. setUseOpenCL(True)
    print(f'OpenCL available:  {cv2.ocl.useOpenCL()}')
    print(f'OpenCL device:  {cv2.ocl.Device. getDefault().name()}')
else:
    print('OpenCL not available')
"

echo ""
echo "=== OpenCV build complete ==="
echo "Installed to site-packages"