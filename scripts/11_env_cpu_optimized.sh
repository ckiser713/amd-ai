#!/usr/bin/env bash
set -euo pipefail

echo "⚡ Setting up CPU-optimized environment..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env

# Load hardware detection
if [[ -f "$SCRIPT_DIR/../build_config/hw_detected.env" ]]; then
    source "$SCRIPT_DIR/../build_config/hw_detected.env"
fi

# CPU optimization flags for Zen 5 (Strix Halo)
export CPU_ARCH="${DETECTED_CPU_ARCH:-znver5}"

# Full Zen 5 / Strix Halo AVX-512 optimization flags
# Zen 5 supports: AVX-512F, AVX-512BW, AVX-512VL, AVX-512DQ, AVX-512CD, 
#                 AVX-512VBMI, AVX-512VBMI2, AVX-512VNNI, AVX-512BITALG, AVX-512VPOPCNTDQ
if [[ "$CPU_ARCH" == "znver5" ]]; then
    AVX512_FLAGS="-mavx512f -mavx512bw -mavx512vl -mavx512dq -mavx512cd"
    AVX512_FLAGS="$AVX512_FLAGS -mavx512vbmi -mavx512vbmi2 -mavx512vnni"
    AVX512_FLAGS="$AVX512_FLAGS -mavx512bitalg -mavx512vpopcntdq"
    AVX512_FLAGS="$AVX512_FLAGS -mavx512bf16"  # BFloat16 support on Zen 5
    
    export CFLAGS="-march=$CPU_ARCH -mtune=$CPU_ARCH -O3 $AVX512_FLAGS -pipe -fno-plt -fexceptions -flto=auto -fuse-linker-plugin"
    export CXXFLAGS="-march=$CPU_ARCH -mtune=$CPU_ARCH -O3 $AVX512_FLAGS -pipe -fno-plt -fexceptions -flto=auto -fuse-linker-plugin"
else
    export CFLAGS="-march=$CPU_ARCH -O3 -pipe -fno-plt -fexceptions -flto=auto"
    export CXXFLAGS="-march=$CPU_ARCH -O3 -pipe -fno-plt -fexceptions -flto=auto"
fi

# Linker optimization - prefer mold > lld > gold > ld
# Linker optimization - default to system linker for GCC LTO compatibility
export LDFLAGS="-Wl,-O1,--sort-common,--as-needed,-z,relro,-z,now -flto=auto"

CPU_CORES=${DETECTED_CPU_CORES:-$(nproc --all 2>/dev/null || echo 1)}
if ((CPU_CORES > 0)); then
    export GOMP_CPU_AFFINITY="0-$((CPU_CORES-1))"
fi
export OMP_PROC_BIND="spread"
export OMP_PLACES="threads"
export OMP_STACKSIZE="${OMP_STACKSIZE:-64M}"

export USE_OPENBLAS="1"
export USE_MKL="0"
export USE_CUDA="0"
export USE_ROCM="0"

export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

# Use ccache if available
if command -v ccache &> /dev/null; then
    export CC="ccache gcc"
    export CXX="ccache g++"
else
    export CC="gcc"
    export CXX="g++"
fi

# Python-specific build optimizations
export PYTHON_CONFIGURE_OPTS="--enable-optimizations --with-lto"

echo "✅ CPU environment optimized for $CPU_ARCH"
echo "   CFLAGS: $CFLAGS"
if [[ "$CPU_ARCH" == "znver5" ]]; then
    echo "   AVX-512 extensions: F, BW, VL, DQ, CD, VBMI, VBMI2, VNNI, BITALG, VPOPCNTDQ, BF16"
fi
parallel_env_summary
