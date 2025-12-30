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

# 12. Fix Flash Attention build configuration
# Enable CUDA/ROCm extension build by flipping SKIP_CUDA_BUILD to FALSE
sed -i 's/export FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE/export FLASH_ATTENTION_SKIP_CUDA_BUILD=FALSE/' scripts/31_build_flash_attn.sh

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
# Force reinstall setuptools and wheel to override Debian-patched versions (install_layout bug)
RUN python3.11 -m pip install --force-reinstall --ignore-installed --break-system-packages \
    setuptools wheel
RUN python3.11 -m pip install --break-system-packages \
    ninja meson meson-python cython pybind11 \
    packaging pyyaml typing-extensions \
    sympy mpmath requests psutil tqdm filelock \
    numpy pandas iniconfig pluggy || true

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
# 7.5 Fix AOTriton venv failure (Handled by aotriton.cmake Patch)

# 8. Fix xformers ck_tile warpSize constexpr error
sed -i 's/return warpSize;/#if defined(__AMDGCN_WAVEFRONT_SIZE__)\n    return __AMDGCN_WAVEFRONT_SIZE__;\n#else\n    return warpSize;\n#endif/g' src/extras/xformers/third_party/composable_kernel_tiled/include/ck_tile/core/arch/arch.hpp
sed -i 's/return warpSize;/#if defined(__AMDGCN_WAVEFRONT_SIZE__)\n    return __AMDGCN_WAVEFRONT_SIZE__;\n#else\n    return warpSize;\n#endif/g' src/extras/xformers/third_party/composable_kernel_tiled/include/ck_tile/core/arch/arch_hip.hpp
# 9. Apply Agent Fix for division by zero in xformers
python3 patches/apply_xformers_fix.py

# 10. Fix torchvision duplicate cuda_version symbol (hipify bug creates both vision.cpp and vision_hip.cpp with same function)
# vision.cpp: Exclude cuda_version for ROCm builds
if ! grep -q "USE_ROCM" src/extras/torchvision/torchvision/csrc/vision.cpp; then
    sed -i 's/namespace vision {/namespace vision {\n\/\/ When building with ROCm, cuda_version is defined in vision_hip.cpp\n#if !defined(WITH_HIP) \&\& !defined(USE_ROCM) \&\& !defined(__HIP_PLATFORM_AMD__)/' src/extras/torchvision/torchvision/csrc/vision.cpp
    sed -i 's/} \/\/ namespace vision/#endif \/\/ Non-HIP build\n} \/\/ namespace vision/' src/extras/torchvision/torchvision/csrc/vision.cpp
fi
# vision_hip.cpp: Include cuda_version ONLY for ROCm builds (opposite guard)
if ! grep -q "defined(USE_ROCM)" src/extras/torchvision/torchvision/csrc/vision_hip.cpp; then
    sed -i 's/namespace vision {/namespace vision {\n\/\/ This file provides cuda_version for ROCm\/HIP builds\n#if defined(WITH_HIP) || defined(USE_ROCM) || defined(__HIP_PLATFORM_AMD__)/' src/extras/torchvision/torchvision/csrc/vision_hip.cpp
    sed -i 's/} \/\/ namespace vision/#endif \/\/ HIP\/ROCm build\n} \/\/ namespace vision/' src/extras/torchvision/torchvision/csrc/vision_hip.cpp
fi

# 11. Fix torchvision verification failure (ROCm builds miss _cuda_version op)
# This patches extension.py to handle missing _cuda_version attribute gracefully
python3 -c "
import sys
import os
fn = 'src/extras/torchvision/torchvision/extension.py'
if os.path.exists(fn):
    with open(fn, 'r') as f: content = f.read()
    if 'try:' not in content and '_version = torch.ops.torchvision._cuda_version()' in content:
        patch = '''    # ROCm builds may not have _cuda_version registered - handle gracefully
    try:
        _version = torch.ops.torchvision._cuda_version()
    except AttributeError:
        # _cuda_version not available (ROCm/HIP build) - skip CUDA version check
        return -1'''
        content = content.replace('    _version = torch.ops.torchvision._cuda_version()', patch)
        with open(fn, 'w') as f: f.write(content)
        print('Patched torchvision/extension.py')
"

# 12. Fix Flash Attention build configuration
# Enable CUDA/ROCm extension build by flipping SKIP_CUDA_BUILD to FALSE
sed -i 's/export FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE/export FLASH_ATTENTION_SKIP_CUDA_BUILD=FALSE/' scripts/31_build_flash_attn.sh
echo "Patched scripts/31_build_flash_attn.sh to enable CUDA/ROCm build"

# 13. Fix Flash Attention architecture check
# Add gfx1151 to allowed_archs in setup.py
sed -i 's/"gfx942"/"gfx942", "gfx1151"/' src/extras/flash-attention/setup.py
echo "Patched src/extras/flash-attention/setup.py to allow gfx1151"

# 14. Fix Flash Attention ck_tile warpSize constexpr error
# Patch arch.hpp and arch_hip.hpp to use compile-time __AMDGCN_WAVEFRONT_SIZE__ or hardcoded 32
# This prevents "constexpr function never produces a constant expression" on Host
sed -i 's/return warpSize;/#if defined(__AMDGCN_WAVEFRONT_SIZE__)\n    return __AMDGCN_WAVEFRONT_SIZE__;\n#else\n    return 32;\n#endif/g' src/extras/flash-attention/csrc/composable_kernel/include/ck_tile/core/arch/arch.hpp
sed -i 's/return warpSize;/#if defined(__AMDGCN_WAVEFRONT_SIZE__)\n    return __AMDGCN_WAVEFRONT_SIZE__;\n#else\n    return 32;\n#endif/g' src/extras/flash-attention/csrc/composable_kernel/include/ck_tile/core/arch/arch_hip.hpp
echo "Patched Flash Attention ck_tile for Wave32/constexpr support"

# 15. Fix Flash Attention bfloat16 inline asm mask size
# Wave32 uses 32-bit mask (uint32_t), Wave64 uses 64-bit (uint32x2_t).
# Patch bfloat16.hpp to conditionally define uint32x2_t based on __AMDGCN_WAVEFRONT_SIZE__
# Use wildcard matching to handle indentation and avoid regex escaping issues with parentheses
sed -i 's/.*using uint32x2_t = uint32_t.*ext_vector_type(2).*/#if defined(__AMDGCN_WAVEFRONT_SIZE__) \&\& (__AMDGCN_WAVEFRONT_SIZE__ == 32)\n    using uint32x2_t = uint32_t;\n#else\n    using uint32x2_t = uint32_t __attribute__((ext_vector_type(2)));\n#endif/' src/extras/flash-attention/csrc/composable_kernel/include/ck_tile/core/numeric/bfloat16.hpp
echo "Patched Flash Attention bfloat16.hpp for Wave32 mask support"

# 16. Fix Flash Attention default policy division by zero (Wave32)
# When warpSize (32) < K0, (warpSize / K0) becomes 0, causing division by zero in subsequent calcs.
# Patch block_fmha_bwd_pipeline_default_policy_hip.hpp to enforce min 1.
# Use flexible whitespace matching [ ]* around / to ensure match
sed -i 's/get_warp_size() *\/ *K0/((get_warp_size() \/ K0) > 0 ? (get_warp_size() \/ K0) : 1)/g' src/extras/flash-attention/csrc/composable_kernel/include/ck_tile/ops/fmha/pipeline/block_fmha_bwd_pipeline_default_policy_hip.hpp
# Fix M0/M2 division by zero in Flash Attention default policy (Wave32) - HIP Variant
sed -i 's/kMPerBlock *\/ *(M1 *\* *M2)/kMPerBlock \/ ((M1 * M2) > 0 ? (M1 * M2) : 1)/g' src/extras/flash-attention/csrc/composable_kernel/include/ck_tile/ops/fmha/pipeline/block_fmha_bwd_pipeline_default_policy_hip.hpp
sed -i 's/kMPerBlock *\/ *(M1 *\* *M0)/kMPerBlock \/ ((M1 * M0) > 0 ? (M1 * M0) : 1)/g' src/extras/flash-attention/csrc/composable_kernel/include/ck_tile/ops/fmha/pipeline/block_fmha_bwd_pipeline_default_policy_hip.hpp
# Fix M0/M2 division by zero in Flash Attention default policy (Wave32) - Non-HIP Variant (Just in case)
sed -i 's/get_warp_size() *\/ *K0/((get_warp_size() \/ K0) > 0 ? (get_warp_size() \/ K0) : 1)/g' src/extras/flash-attention/csrc/composable_kernel/include/ck_tile/ops/fmha/pipeline/block_fmha_bwd_pipeline_default_policy.hpp
sed -i 's/kMPerBlock *\/ *(M1 *\* *M2)/kMPerBlock \/ ((M1 * M2) > 0 ? (M1 * M2) : 1)/g' src/extras/flash-attention/csrc/composable_kernel/include/ck_tile/ops/fmha/pipeline/block_fmha_bwd_pipeline_default_policy.hpp
sed -i 's/kMPerBlock *\/ *(M1 *\* *M0)/kMPerBlock \/ ((M1 * M0) > 0 ? (M1 * M0) : 1)/g' src/extras/flash-attention/csrc/composable_kernel/include/ck_tile/ops/fmha/pipeline/block_fmha_bwd_pipeline_default_policy.hpp
echo "Patched Flash Attention default_policy (HIP & Base) for Wave32 division-by-zero safety (M0/M2)"

# 17. Fix Flash Attention ck_tile inline assembly for Wave32 (v_cmpx implicit exec)
# RDNA3/Wave32 assembler rejects explicit 'exec' destination for v_cmpx
sed -i 's/v_cmpx_le_u32 exec,/v_cmpx_le_u32/g' src/extras/flash-attention/csrc/composable_kernel/include/ck_tile/core/arch/amd_buffer_addressing_builtins_hip.hpp
echo "Patched Flash Attention ck_tile inline assembly for Wave32 compatibility"

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
    -e PIP_FIND_LINKS="/app/artifacts /app/wheels/cache" \
    -e MAX_JOBS="$TARGET_JOBS" \
    -e PARALLEL_MODE=pin \
    -e DETECTED_GPU_ARCH="${DETECTED_GPU_ARCH:-gfx1151}" \
    -e DETECTED_CPU_ARCH="${DETECTED_CPU_ARCH:-znver5}" \
    -e HSA_OVERRIDE_GFX_VERSION=11.0.0 \
    -e ROCBLAS_STREAM_ORDER_ALLOC=1 \
    -e GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 \
    -e VLLM_ENFORCE_EAGER=true \
    -e ROCSHMEM_DISABLE_MIXED_IPC=1 \
    -e PYTORCH_ROCM_ARCH=gfx1151 \
    -e HCC_AMDGPU_TARGET=gfx1151 \
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
