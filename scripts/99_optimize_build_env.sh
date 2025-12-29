#!/usr/bin/env bash
set -euo pipefail

echo "🎛️  Tuning system for optimal AMD Zen 5 Strix Halo build performance..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env

# Detect memory size
MEM_GB=$(_parallel_mem_gb)

# Set CPU governor to performance
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
    echo "✅ CPU governor: performance mode"
fi

# Increase dirty writeback memory (helps with many parallel file writes)
# Scale with available memory - larger values for 128GB+ systems
if ((MEM_GB >= 128)); then
    echo "3000" | sudo tee /proc/sys/vm/dirty_writeback_centisecs >/dev/null 2>&1 || true
    echo "60" | sudo tee /proc/sys/vm/dirty_ratio >/dev/null 2>&1 || true
    echo "20" | sudo tee /proc/sys/vm/dirty_background_ratio >/dev/null 2>&1 || true
    # Increase max map count for large builds
    echo "262144" | sudo tee /proc/sys/vm/max_map_count >/dev/null 2>&1 || true
elif ((MEM_GB >= 64)); then
    echo "2500" | sudo tee /proc/sys/vm/dirty_writeback_centisecs >/dev/null 2>&1 || true
    echo "50" | sudo tee /proc/sys/vm/dirty_ratio >/dev/null 2>&1 || true
    echo "15" | sudo tee /proc/sys/vm/dirty_background_ratio >/dev/null 2>&1 || true
else
    echo "2000" | sudo tee /proc/sys/vm/dirty_writeback_centisecs >/dev/null 2>&1 || true
    echo "40" | sudo tee /proc/sys/vm/dirty_ratio >/dev/null 2>&1 || true
    echo "10" | sudo tee /proc/sys/vm/dirty_background_ratio >/dev/null 2>&1 || true
fi

# Increase file descriptors for many parallel jobs
ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true

# Set process priority for build tools
if command -v nice &> /dev/null; then
    renice -n -10 $$ 2>/dev/null || renice -n -5 $$ 2>/dev/null || true
fi

# Memory optimization for large parallel builds - tuned for Strix Halo
export MALLOC_MMAP_THRESHOLD_=262144
export MALLOC_TRIM_THRESHOLD_=262144
export MALLOC_TOP_PAD_=262144
export MALLOC_MMAP_MAX_=65536

# Enable transparent huge pages for large memory systems
if ((MEM_GB >= 64)); then
    echo "madvise" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
fi

# AMD Zen 5-specific OpenMP optimization
CPU_CORES=$(nproc --all 2>/dev/null || echo 1)
if ((CPU_CORES > 0)); then
    export GOMP_CPU_AFFINITY="0-$((CPU_CORES-1))"
fi
export OMP_PROC_BIND=${OMP_PROC_BIND:-spread}
export OMP_PLACES=${OMP_PLACES:-threads}
export OMP_DYNAMIC=${OMP_DYNAMIC:-false}
export OMP_NESTED=${OMP_NESTED:-false}
export OMP_MAX_ACTIVE_LEVELS=${OMP_MAX_ACTIVE_LEVELS:-1}
export OMP_STACKSIZE=${OMP_STACKSIZE:-64M}

# AMD GPU performance (if ROCm is present)
if [[ -d /opt/rocm ]]; then
    # Set GPU to high performance mode
    if command -v rocm-smi &> /dev/null; then
        rocm-smi --setperflevel high 2>/dev/null || true
    fi
    # Enable HIP async memory operations
    export HIP_LAUNCH_BLOCKING=0
    export HIP_FORCE_DEV_KERNARG=1
    export HSA_ENABLE_SDMA=1
fi

# Compiler cache optimization
if command -v ccache &> /dev/null; then
    # Ensure ccache is in PATH for automatic use
    export PATH="/usr/lib/ccache:$PATH"
fi

# tmpfs for build directories if memory allows (128GB+ systems)
if ((MEM_GB >= 128)); then
    export USE_TMPFS_BUILD=${USE_TMPFS_BUILD:-1}
    echo "💾 Sufficient memory for tmpfs builds: ${MEM_GB}GB available"
fi

parallel_env_summary

echo ""
echo "🔧 Build environment optimized for AMD Strix Halo"
echo "   Available jobs: $MAX_JOBS"
echo "   Memory: ${MEM_GB}GB total"
echo "   CPU cores: $CPU_CORES"
echo "   File descriptors: $(ulimit -n)"
if [[ -n "${CCACHE_DIR:-}" ]]; then
    echo "   ccache dir: $CCACHE_DIR (max: $CCACHE_MAXSIZE)"
fi
