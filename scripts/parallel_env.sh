#!/usr/bin/env bash

# Shared helpers for squeezing the most out of local CPU + memory during builds.
# Optimized for AMD Strix Halo 395+MAX with 128GB unified memory.
# This file is intended to be sourced by build scripts; it does not set shell
# options that would leak to callers.
#
# Parallelism Policy Knob:
# PARALLEL_MODE=${PARALLEL_MODE:-force}
#   - force (default): Override inherited parallel vars (MAX_JOBS, MAKEFLAGS, etc.)
#                      to calculated system capacity.
#   - pin: Use PARALLEL_JOBS (or fallback to MAX_JOBS) as the explicit job count.
#   - respect: Keep existing environment variables if set (legacy behavior).
#
# PARALLEL_JOBS: Explicit job count for 'pin' mode.

# Debug helper
_log_parallel() {
  if [[ "${PARALLEL_DEBUG:-0}" == "1" ]]; then
    echo "[parallel_env] $*" >&2
  fi
}

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

# Decide how many parallel jobs to run, respecting optional overrides.
parallel_calculate_jobs() {
  local mode="${PARALLEL_MODE:-force}"
  local jobs

  # 1. PIN Mode
  if [[ "$mode" == "pin" ]]; then
    # Use PARALLEL_JOBS if set, otherwise fallback to MAX_JOBS
    jobs="${PARALLEL_JOBS:-${MAX_JOBS:-}}"
    # Validate
    if [[ -z "$jobs" ]] || ! [[ "$jobs" =~ ^[0-9]+$ ]] || ((jobs < 1)); then
       _log_parallel "Pin mode requested but PARALLEL_JOBS/MAX_JOBS invalid. Falling back to detection."
    else
       echo "$jobs"
       return
    fi
  fi

  # 2. Calculation (Force or Respect or Pin-fallback)
  local cores reserve usable mem_gb per_job_gb mem_limited
  
  # Use nproc (cgroup aware) as primary.
  # Record nproc --all for diagnostics logic (not implementing full warning here to keep it simple, accessible in summary)
  cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  
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
  if _is_high_mem_apu; then
    per_job_gb=${JOB_MEM_GB:-1} # Relaxed from 4GB to 1GB to ensure core saturation
  else
    per_job_gb=${JOB_MEM_GB:-2}
  fi
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

  # Debug logging for calculation
  local host_cores
  host_cores=$(nproc --all 2>/dev/null || echo "?")
  _log_parallel "Calc: Cores=${cores}/${host_cores}, Mem=${mem_gb}GB, PerJob=${per_job_gb}GB -> Limit: Mem=${mem_limited}, Core=${usable}"

  # 3. RESPECT Mode: If MAX_JOBS is already set, respect it.
  # (Unlike previous version, we ONLY do this if mode is respect, or implicitly via the fact we are calculating)
  # Wait, if mode is RESPECT, we should use MAX_JOBS if set.
  if [[ "$mode" == "respect" ]] && [[ -n "${MAX_JOBS:-}" ]]; then
      jobs=$MAX_JOBS
  fi

  echo "$jobs"
}

# Apply environment variables that build tools honor for parallelism and BLAS.
# Remove -jN or --jobs=N from a flag string
_clean_parallel_flags() {
  local input="$1"
  # Replace -j[0-9]+ and --jobs=[0-9]+ with empty string
  # Also handle bare -j [0-9]+ is harder in sed, assuming standard glued format or single -j
  local clean
  clean=$(echo "$input" | sed -E 's/-j[0-9]+//g' | sed -E 's/--jobs=[0-9]+//g' | sed -E 's/-j //g')
  # Trim extra spaces
  echo "$clean" | xargs
}

# Apply environment variables that build tools honor for parallelism and BLAS.
apply_parallel_env() {
  local jobs mode
  mode="${PARALLEL_MODE:-force}"
  jobs="$(parallel_calculate_jobs)"
  
  # Ensure valid integer
  if [[ -z "$jobs" ]] || ! [[ "$jobs" =~ ^[0-9]+$ ]] || ((jobs < 1)); then
    jobs=4
  fi

  local mem_gb
  mem_gb=$(_parallel_mem_gb)
  
  _log_parallel "Applying Policy: $mode (Target Jobs: $jobs)"

  if [[ "$mode" == "respect" ]]; then
     # --- RESPECT MODE (Legacy) ---
     export MAX_JOBS="${MAX_JOBS:-$jobs}"
     export NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
     export PARALLEL_LEVEL="${PARALLEL_LEVEL:-$MAX_JOBS}"
     export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
     export GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"
     
     # Flags: append if not set, otherwise keep
     export NINJAFLAGS="${NINJAFLAGS:--j$MAX_JOBS}"
     export MAKEFLAGS="${MAKEFLAGS:--j$MAX_JOBS}"

     export DS_BUILD_PARALLEL_LEVEL="${DS_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
     export SKLEARN_BUILD_PARALLEL_LEVEL="${SKLEARN_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

     local omp="${OMP_NUM_THREADS:-$MAX_JOBS}"
     export OMP_NUM_THREADS="$omp"
     export MKL_NUM_THREADS="${MKL_NUM_THREADS:-$omp}"
     export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-$omp}"
     export BLIS_NUM_THREADS="${BLIS_NUM_THREADS:-$omp}"
     export NUMEXPR_MAX_THREADS="${NUMEXPR_MAX_THREADS:-$omp}"
     export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-$MAX_JOBS}"
     
     # Return early
  else
     # --- FORCE / PIN MODE ---
     # Overwrite core variables
     export MAX_JOBS="$jobs"
     export NUM_JOBS="$jobs"
     export PARALLEL_LEVEL="$jobs"
     export CMAKE_BUILD_PARALLEL_LEVEL="$jobs"
     export GIT_JOBS="$jobs"
     
     # Overwrite library specific vars
     export DS_BUILD_PARALLEL_LEVEL="$jobs"
     export SKLEARN_BUILD_PARALLEL_LEVEL="$jobs"
     export UV_THREADPOOL_SIZE="$jobs"
     
     # OMP/BLAS - Overwrite to match jobs (for build saturation)
     export OMP_NUM_THREADS="$jobs"
     export MKL_NUM_THREADS="$jobs"
     export OPENBLAS_NUM_THREADS="$jobs"
     export BLIS_NUM_THREADS="$jobs"
     export NUMEXPR_MAX_THREADS="$jobs"
     
     # Flags: Clean and Append
     local clean_make
     clean_make=$(_clean_parallel_flags "${MAKEFLAGS:-}")
     # Ensure we don't end up with empty string causing issues? No, empty MAKEFLAGS is fine.
     export MAKEFLAGS="${clean_make} -j$jobs"
     
     local clean_ninja
     clean_ninja=$(_clean_parallel_flags "${NINJAFLAGS:-}")
     export NINJAFLAGS="${clean_ninja} -j$jobs"
  fi

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
  local arch="${DETECTED_CPU_ARCH:-znver5}"
  local base_cflags="-march=$arch -mtune=$arch -O3 -pipe -fno-plt -fexceptions"
  local avx_flags="-mavx512f -mavx512bw -mavx512vl -mavx512dq -mavx512cd -mavx512vbmi -mavx512vbmi2 -mavx512vnni -mavx512bitalg -mavx512vpopcntdq"
  local lto_flags="-flto=auto -fuse-linker-plugin"
  
  export ZEN5_CFLAGS="$base_cflags $avx_flags $lto_flags"
  export ZEN5_CXXFLAGS="$ZEN5_CFLAGS"
  
  # Apply if not already set
  export CFLAGS="${CFLAGS:-$ZEN5_CFLAGS}"
  export CXXFLAGS="${CXXFLAGS:-$ZEN5_CXXFLAGS}"
}

parallel_env_summary() {
  local mem_gb cores host_cores high_mem_status
  mem_gb=$(_parallel_mem_gb)
  cores=$(nproc 2>/dev/null || echo "unknown")
  host_cores=$(nproc --all 2>/dev/null || echo "unknown")
  
  if _is_high_mem_apu; then
    high_mem_status="High-mem APU mode (128GB+)"
  else
    high_mem_status="Standard mode"
  fi
  
  echo "🧮 Parallel config -> jobs=$MAX_JOBS"
  echo "    Mode Config: PARALLEL_MODE=${PARALLEL_MODE:-force}, PIN=${PARALLEL_JOBS:-none}"
  echo "    System: Usage Cpus=$cores, Host Cpus=$host_cores, Mem=${mem_gb}GiB ($high_mem_status)"
  echo "    MAKEFLAGS=$MAKEFLAGS"
  echo "    NINJAFLAGS=$NINJAFLAGS"
  echo "    CMAKE_BUILD_PARALLEL_LEVEL=$CMAKE_BUILD_PARALLEL_LEVEL"
  echo "    CCACHE_MAXSIZE=$CCACHE_MAXSIZE"
  if [[ -n "${LDFLAGS:-}" ]]; then
    echo "    LDFLAGS=$LDFLAGS"
  fi
}
