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
export CFLAGS="-march=$CPU_ARCH -O3 -pipe -fno-plt -fexceptions -flto=auto"
export CXXFLAGS="-march=$CPU_ARCH -O3 -pipe -fno-plt -fexceptions -flto=auto"
export LDFLAGS="-Wl,-O1,--sort-common,--as-needed,-z,relro,-z,now -flto=auto"

CPU_CORES=${DETECTED_CPU_CORES:-$(nproc --all 2>/dev/null || echo 1)}
if ((CPU_CORES > 0)); then
    export GOMP_CPU_AFFINITY="0-$((CPU_CORES-1))"
fi
export OMP_PROC_BIND="spread"
export OMP_PLACES="threads"

export USE_OPENBLAS="1"
export USE_MKL="0"
export USE_CUDA="0"
export USE_ROCM="0"

export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
export CC="gcc"
export CXX="g++"

echo "✅ CPU environment optimized for $CPU_ARCH"
echo "   CFLAGS: $CFLAGS"
parallel_env_summary
