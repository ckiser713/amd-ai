#!/usr/bin/env bash
set -euo pipefail

echo "🎛️  Tuning system for optimal AMD Zen 4 build performance..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env

# Set CPU governor to performance
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
    echo "✅ CPU governor: performance mode"
fi

# Increase dirty writeback memory (helps with many parallel file writes)
echo "2000" | sudo tee /proc/sys/vm/dirty_writeback_centisecs >/dev/null
echo "50" | sudo tee /proc/sys/vm/dirty_ratio >/dev/null
echo "10" | sudo tee /proc/sys/vm/dirty_background_ratio >/dev/null

# Increase file descriptors for many parallel jobs
ulimit -n 65536 2>/dev/null || true

# Set process priority for build tools
if command -v nice &> /dev/null; then
    renice -n -5 $$ 2>/dev/null || true
fi

# Memory optimization for large parallel builds
export MALLOC_MMAP_THRESHOLD_=131072
export MALLOC_TRIM_THRESHOLD_=131072

# AMD-specific optimization
CPU_CORES=$(nproc --all 2>/dev/null || echo 1)
if ((CPU_CORES > 0)); then
    export GOMP_CPU_AFFINITY="0-$((CPU_CORES-1))"
fi
export OMP_PROC_BIND=${OMP_PROC_BIND:-spread}
export OMP_PLACES=${OMP_PLACES:-threads}

parallel_env_summary

echo "🔧 Build environment optimized for parallel builds"
echo "   Available jobs: $MAX_JOBS"
echo "   Memory: $(free -h | awk '/^Mem:/ {print $2}') total"
