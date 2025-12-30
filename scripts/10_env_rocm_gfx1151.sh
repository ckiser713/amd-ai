#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Setting up ROCm environment..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env

# Load hardware detection
if [[ -f "$SCRIPT_DIR/../build_config/hw_detected.env" ]]; then
    source "$SCRIPT_DIR/../build_config/hw_detected.env"
fi

# ROCm paths (ROCm 7.1.1 default)
export ROCM_VERSION="7.1.1"
# If hipconfig reports a versioned ROCm prefix (e.g., /opt/rocm-7.1.1), prefer it
HIPCONFIG_PATH=""
if command -v hipconfig &> /dev/null; then
    HIPCONFIG_PATH="$(hipconfig --path 2>/dev/null || true)"
fi
export ROCM_PATH="${HIPCONFIG_PATH:-/opt/rocm}"
export HIP_PATH="$ROCM_PATH"
export HIP_ROOT_DIR="$ROCM_PATH"
export HIP_DIR="$ROCM_PATH/lib/cmake/hip"
export CMAKE_PREFIX_PATH="$ROCM_PATH${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

# Strix Halo / Kernel 6.14+ Stabilizers
export HSA_OVERRIDE_GFX_VERSION=11.0.0 # Fixes Node-1 Memory Access Fault
export ROCBLAS_STREAM_ORDER_ALLOC=1    # Prevents OOM/Corruption

if [[ -d "$ROCM_PATH/lib/cmake" ]]; then
    export CMAKE_PREFIX_PATH="$ROCM_PATH/lib/cmake:${CMAKE_PREFIX_PATH}"
fi

# GPU architecture (fallback to gfx1151 if not detected)
export ROCM_GFX_ARCH="${DETECTED_GPU_ARCH:-gfx1151}"
export PYTORCH_ROCM_ARCH="$ROCM_GFX_ARCH"
export HCC_AMDGPU_TARGET="$ROCM_GFX_ARCH"

# ROCm library paths
export LD_LIBRARY_PATH="$ROCM_PATH/lib:$ROCM_PATH/lib64:$HIP_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$ROCM_PATH/bin:$HIP_PATH/bin:$ROCM_PATH/llvm/bin${PATH:+:$PATH}"

# Performance optimizations
export HIP_VISIBLE_DEVICES="0"  # Use first GPU
export HIP_LAUNCH_BLOCKING="0"  # Non-blocking kernel launches
export HIP_FORCE_DEV_KERNARG="1"  # Improve kernel launch latency
export HIP_PROFILE_API="0"  # Disable profiling unless needed

# ROCm-specific math libraries
export MIOpen_DISABLE_CACHE="0"
export MIOPEN_FIND_MODE="NORMAL"

CPU_CORES=${DETECTED_CPU_CORES:-$(nproc --all 2>/dev/null || echo 1)}
if ((CPU_CORES > 0)); then
    export GOMP_CPU_AFFINITY="0-$((CPU_CORES-1))"
fi
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

echo "✅ ROCm environment set for $ROCM_GFX_ARCH"
echo "   ROCM_PATH: $ROCM_PATH"
echo "   HIP_PATH: $HIP_PATH"
echo "   GPU Target: $ROCM_GFX_ARCH"
parallel_env_summary
