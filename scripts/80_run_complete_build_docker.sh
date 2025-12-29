#!/bin/bash
# scripts/80_run_complete_build_docker.sh
# Orchestrates the entire project build inside a clean ROCm Docker container.

set -e

# Parse arguments
SKIP_PREFETCH=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip)
            SKIP_PREFETCH=true
            shift
            ;;
        --kill)
            echo "🛑 Killing all running Docker containers..."
            docker ps -q | xargs -r docker kill 2>/dev/null || true
            docker ps -a -q | xargs -r docker rm 2>/dev/null || true
            echo "✅ All containers cleaned."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip] [--kill]"
            echo "  --skip: Skip the dependency prefetch stage"
            echo "  --kill: Kill and remove all Docker containers then exit"
            exit 1
            ;;
    esac
done

# Repository Root Detection
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Host Context Setup ---
# Source environment and hardware detection on the host
if [[ -f scripts/parallel_env.sh ]]; then
    source scripts/parallel_env.sh
fi

if [[ -f build_config/hw_detected.env ]]; then
    source build_config/hw_detected.env
else
    echo "Warning: build_config/hw_detected.env not found. Hardware info may be missing."
fi

# Calculate Host-Calculated Parallelism
# 80% of system capacity to avoid freezing the host, pinned for the container.
TOTAL_CORES=$(nproc)
TARGET_JOBS=$(( TOTAL_CORES * 80 / 100 ))
if [[ "$TARGET_JOBS" -lt 1 ]]; then TARGET_JOBS=1; fi

echo "=== Host-Side Parallelism Calculation ==="
echo "Host Cores: $TOTAL_CORES"
echo "Target Jobs (80%): $TARGET_JOBS"
echo "Detected Arch: CPU=${DETECTED_CPU_ARCH:-unknown}, GPU=${DETECTED_GPU_ARCH:-unknown}"

# Kill any running amd-ai-builder containers
echo "=== Cleaning up old containers ==="
docker ps -a --filter "ancestor=amd-ai-builder:local" --format "{{.ID}}" | xargs -r docker kill 2>/dev/null || true
docker ps -a --filter "ancestor=amd-ai-builder:local" --format "{{.ID}}" | xargs -r docker rm 2>/dev/null || true

echo "=== AMD AI Builder: Initializing Docker Infrastructure ==="

# Step A: Define & Build the Builder Image
echo "Building amd-ai-builder:local..."
docker build -t amd-ai-builder:local -f - . <<EOF
FROM rocm/dev-ubuntu-24.04:7.1.1-complete

# Avoid interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Install System Dependencies (Python 3.11 via deadsnakes PPA)
RUN apt-get update && apt-get install -y \
    software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y \
    python3.11 \
    python3.11-venv \
    python3.11-dev \
    python3.11-full \
    python3-pip \
    gcc-14 \
    g++-14 \
    git \
    cmake \
    ninja-build \
    build-essential \
    wget \
    libopenblas-dev \
    libjpeg-dev \
    zlib1g-dev \
    libpng-dev \
    libtiff-dev \
    libfreetype6-dev \
    liblcms2-dev \
    libwebp-dev \
    liblzma-dev \
    libffi-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Set GCC 14 and Python 3.11 as default
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100 --slave /usr/bin/g++ g++ /usr/bin/g++-14 && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1

# Ensure pip is installed for Python 3.11 and install essential build dependencies
RUN python3.11 -m pip install --upgrade pip --break-system-packages || true
RUN python3.11 -m pip install --break-system-packages \
    ninja meson meson-python cython pybind11 \
    setuptools wheel packaging pyyaml typing-extensions \
    sympy mpmath requests psutil tqdm || true

# Set Environment Variables
ENV ROCM_PATH=/opt/rocm
ENV PATH=\$ROCM_PATH/bin:\$ROCM_PATH/llvm/bin:\$PATH

WORKDIR /app
EOF

echo "=== AMD AI Builder: Starting Containerized Build Pipeline ==="

# Step B: Prefetch All Dependencies on Host
if [ "$SKIP_PREFETCH" = false ]; then
    echo "Running prefetch stage..."
    bash scripts/06_prefetch_all_dependencies.sh
else
    echo ">>> Skipping prefetch stage (--skip flag set)..."
fi

# Step B.5: Apply Patches (Ensure they survive prefetch)
echo "Applying Triton ROCm patches..."
# 1. Disable -Werror for literal operators
sed -i 's/-Werror -Wno-covered-switch-default/-Werror -Wno-covered-switch-default -Wno-error=deprecated-literal-operator/g' src/extras/triton-rocm/CMakeLists.txt
# 2. Disable Unit Tests
sed -i 's/option(TRITON_BUILD_UT "Build C++ Triton Unit Tests" ON)/option(TRITON_BUILD_UT "Build C++ Triton Unit Tests" OFF)/g' src/extras/triton-rocm/CMakeLists.txt
# 3. Disable Lit Test Support Libs
sed -i 's/add_subdirectory(test)/# add_subdirectory(test)/g' src/extras/triton-rocm/CMakeLists.txt
# 4. Disable Bin Tools (LSP, Opt)
sed -i 's/add_subdirectory(bin)/# add_subdirectory(bin)/g' src/extras/triton-rocm/CMakeLists.txt
# 5. Remove NVIDIA IR from common conversion libs (Fix ROCm link error)
sed -i '/TritonNvidiaGPUTransforms/d' src/extras/triton-rocm/lib/Conversion/TritonGPUToLLVM/CMakeLists.txt
sed -i '/NVGPUIR/d' src/extras/triton-rocm/lib/Conversion/TritonGPUToLLVM/CMakeLists.txt
# 6. Prune NVIDIA backend from source to avoid discovery issues
rm -rf src/extras/triton-rocm/python/triton/backends/nvidia
# 7. Fix Verification: must run from outside source tree (Idempotent patch)
if ! grep -q "cd /tmp && python" scripts/22_build_triton_rocm.sh; then
    sed -i 's/python -c/cd \/tmp \&\& python -c/g' scripts/22_build_triton_rocm.sh
fi

# Step C: Execute the Build Pipeline
# Injected Env Vars:
#   MAX_JOBS: Pinned job count (80% of host)
#   PARALLEL_MODE: 'pin' (forces container scripts to respect MAX_JOBS)
#   DETECTED_*: Hardware info
docker run --rm \
    -v "$ROOT_DIR:/app" \
    --user "$(id -u):$(id -g)" \
    --device=/dev/kfd \
    --device=/dev/dri \
    --group-add video \
    --ipc=host \
    -v "$ROOT_DIR/wheels/cache/triton_deps:/tmp/.triton" \
    -e ROCM_PATH=/opt/rocm \
    -e HOME=/tmp \
    -e PIP_NO_INDEX=1 \
    -e PIP_FIND_LINKS=/app/wheels/cache \
    -e MAX_JOBS="$TARGET_JOBS" \
    -e PARALLEL_MODE=pin \
    -e DETECTED_GPU_ARCH="${DETECTED_GPU_ARCH:-}" \
    -e DETECTED_CPU_ARCH="${DETECTED_CPU_ARCH:-znver5}" \
    amd-ai-builder:local \
    bash scripts/internal_container_build.sh

# Step C: Verification
echo "=== AMD AI Builder: Host Verification ==="
if [ -d "artifacts" ]; then
    echo "Contents of artifacts/ directory:"
    ls -R artifacts/
else
    echo "Warning: artifacts/ directory not found. Build might have failed or not produced artifacts."
fi

echo "Done."
