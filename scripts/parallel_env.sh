#!/usr/bin/env bash

# Shared helpers for squeezing the most out of local CPU + memory during builds.
# Optimized for AMD Strix Halo 395+MAX with 128GB unified memory.
# This file is intended to be sourced by build scripts; it does not set shell
# options that would leak to callers.

# Return total memory in GiB (rounded down). Falls back to 0 on failure.
_parallel_mem_gb() {
  local mem_kb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  printf '%s' $((mem_kb / 1024 / 1024))
}

# Detect if this is a Strix Halo / high-memory APU system
_is_high_mem_apu() {
  local mem_gb
  mem_gb=$(_parallel_mem_gb)
  # 64GB+ systems with AMD APU are considered high-memory
  ((mem_gb >= 64))
}

# Decide how many parallel jobs to run, respecting optional overrides:
# - MAX_JOBS: hard override
# - RESERVED_CORES: cores to keep free (default: 0 for high-mem APU, 1 otherwise)
# - JOB_MEM_GB: assumed memory needed per job (default: 1.5 GiB for high-mem, 2 otherwise)
parallel_calculate_jobs() {
  local cores reserve usable mem_gb per_job_gb mem_limited jobs

  cores=$(nproc --all 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  
  # For 128GB+ systems, use all cores; smaller systems reserve 1
  if _is_high_mem_apu; then
    reserve=${RESERVED_CORES:-0}
  else
    reserve=${RESERVED_CORES:-1}
  fi
  ((reserve < 0)) && reserve=0
  usable=$((cores > reserve ? cores - reserve : 1))

  mem_gb=$(_parallel_mem_gb)
  
  # High-memory systems can afford more memory per job for faster compilation
  # With 128GB, we can easily afford 1.5GB per job which allows maxing out even 64+ threads
  if _is_high_mem_apu; then
    per_job_gb=${JOB_MEM_GB:-1} # Relaxed from 4GB to 1GB to ensure core saturation
  else
    per_job_gb=${JOB_MEM_GB:-2}
  fi
  # Floating point handling in bash is tricky, treating as int 1 minimum
  [[ "$per_job_gb" =~ ^[0-9]+$ ]] || per_job_gb=1

  if ((mem_gb > 0)); then
    mem_limited=$((mem_gb / per_job_gb))
    ((mem_limited < 1)) && mem_limited=1
  else
    mem_limited=$usable
  fi

  jobs=$usable
  if ((mem_limited > 0 && mem_limited < jobs)); then
    jobs=$mem_limited
  fi

  if [[ -n "${MAX_JOBS:-}" ]]; then
    jobs=$MAX_JOBS
  fi

  echo "$jobs"
}

# Apply environment variables that build tools honor for parallelism and BLAS.
apply_parallel_env() {
  local jobs omp_threads mem_gb
  jobs="$(parallel_calculate_jobs)"
  mem_gb=$(_parallel_mem_gb)

  # Ensure jobs is never empty or zero - fallback to 4 if detection fails
  if [[ -z "$jobs" ]] || ! [[ "$jobs" =~ ^[0-9]+$ ]] || ((jobs < 1)); then
    jobs=4
  fi

  export MAX_JOBS="${MAX_JOBS:-$jobs}"
  # Double-check MAX_JOBS is valid
  if [[ -z "$MAX_JOBS" ]] || ! [[ "$MAX_JOBS" =~ ^[0-9]+$ ]] || ((MAX_JOBS < 1)); then
    export MAX_JOBS=4
  fi

  export NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
  export PARALLEL_LEVEL="${PARALLEL_LEVEL:-$MAX_JOBS}"
  export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
  export NINJAFLAGS="${NINJAFLAGS:--j$MAX_JOBS}"
  # Use -j format (not --jobs=) for better compatibility
  export MAKEFLAGS="${MAKEFLAGS:--j$MAX_JOBS}"
  export GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"

  # DeepSpeed and other library specific parallel flags
  export DS_BUILD_PARALLEL_LEVEL="${DS_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
  export SKLEARN_BUILD_PARALLEL_LEVEL="${SKLEARN_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

  omp_threads="${OMP_NUM_THREADS:-$MAX_JOBS}"
  export OMP_NUM_THREADS="$omp_threads"
  export MKL_NUM_THREADS="${MKL_NUM_THREADS:-$omp_threads}"
  export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-$omp_threads}"
  export BLIS_NUM_THREADS="${BLIS_NUM_THREADS:-$omp_threads}"
  export NUMEXPR_MAX_THREADS="${NUMEXPR_MAX_THREADS:-$omp_threads}"
  export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-$MAX_JOBS}"

  # ccache defaults for faster rebuilds - scale with available memory
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
  if ((mem_gb >= 128)); then
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-50G}"
  elif ((mem_gb >= 64)); then
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-30G}"
  else
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
  fi
  export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-time_macros,include_file_mtime,file_macro}"
  export CCACHE_COMPRESS="${CCACHE_COMPRESS:-1}"
  export CCACHE_COMPRESSLEVEL="${CCACHE_COMPRESSLEVEL:-1}"
  mkdir -p "$CCACHE_DIR" 2>/dev/null || true

  # Enable ccache for compilers if available
  if command -v ccache &> /dev/null; then
    export CC="${CC:-ccache gcc}"
    export CXX="${CXX:-ccache g++}"
    export HIPCC_COMPILE_FLAGS_APPEND="${HIPCC_COMPILE_FLAGS_APPEND:---ccache-flag=-Xcompiler}"
  fi

  # Linker optimization - disabled to prevent GCC LTO incompatibility with lld/mold
  # if command -v mold &> /dev/null; then
  #   export LDFLAGS="${LDFLAGS:-} -fuse-ld=mold"
  # elif command -v lld &> /dev/null; then
  #   export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld"
  # fi

  # Memory-mapped I/O optimization for large builds
  export MALLOC_MMAP_THRESHOLD_="${MALLOC_MMAP_THRESHOLD_:-131072}"
  export MALLOC_TRIM_THRESHOLD_="${MALLOC_TRIM_THRESHOLD_:-131072}"
  export MALLOC_TOP_PAD_="${MALLOC_TOP_PAD_:-131072}"
  
  # Python wheel building parallelism
  export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_TORCH="${SETUPTOOLS_SCM_PRETEND_VERSION:-}"
  export PIP_NO_BUILD_ISOLATION="${PIP_NO_BUILD_ISOLATION:-0}"
}

# Zen 5 specific CPU flags for maximum performance
apply_zen5_cflags() {
  local base_cflags="-march=znver5 -mtune=znver5 -O3 -pipe -fno-plt -fexceptions"
  local avx_flags="-mavx512f -mavx512bw -mavx512vl -mavx512dq -mavx512cd -mavx512vbmi -mavx512vbmi2 -mavx512vnni -mavx512bitalg -mavx512vpopcntdq"
  local lto_flags="-flto=auto -fuse-linker-plugin"
  
  export ZEN5_CFLAGS="$base_cflags $avx_flags $lto_flags"
  export ZEN5_CXXFLAGS="$ZEN5_CFLAGS"
  
  # Apply if not already set
  export CFLAGS="${CFLAGS:-$ZEN5_CFLAGS}"
  export CXXFLAGS="${CXXFLAGS:-$ZEN5_CXXFLAGS}"
}

parallel_env_summary() {
  local mem_gb cores high_mem_status
  mem_gb=$(_parallel_mem_gb)
  cores=$(nproc --all 2>/dev/null || echo "unknown")
  
  if _is_high_mem_apu; then
    high_mem_status="High-mem APU mode (128GB+)"
  else
    high_mem_status="Standard mode"
  fi
  
  echo "🧮 Parallel config -> jobs=$MAX_JOBS, cores=$cores, mem=${mem_gb}GiB"
  echo "    Mode: $high_mem_status"
  echo "    MAKEFLAGS=$MAKEFLAGS"
  echo "    NINJAFLAGS=$NINJAFLAGS"
  echo "    CMAKE_BUILD_PARALLEL_LEVEL=$CMAKE_BUILD_PARALLEL_LEVEL"
  echo "    CCACHE_MAXSIZE=$CCACHE_MAXSIZE"
  if [[ -n "${LDFLAGS:-}" ]]; then
    echo "    LDFLAGS=$LDFLAGS"
  fi
}
