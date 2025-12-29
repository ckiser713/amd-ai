#!/usr/bin/env bash

# Shared helpers for squeezing the most out of local CPU + memory during builds.
# This file is intended to be sourced by build scripts; it does not set shell
# options that would leak to callers.

# Return total memory in GiB (rounded down). Falls back to 0 on failure.
_parallel_mem_gb() {
  local mem_kb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  printf '%s' $((mem_kb / 1024 / 1024))
}

# Decide how many parallel jobs to run, respecting optional overrides:
# - MAX_JOBS: hard override
# - RESERVED_CORES: cores to keep free (default: 1)
# - JOB_MEM_GB: assumed memory needed per job (default: 2 GiB)
parallel_calculate_jobs() {
  local cores reserve usable mem_gb per_job_gb mem_limited jobs

  cores=$(nproc --all 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  reserve=${RESERVED_CORES:-1}
  ((reserve < 0)) && reserve=0
  usable=$((cores > reserve ? cores - reserve : 1))

  mem_gb=$(_parallel_mem_gb)
  per_job_gb=${JOB_MEM_GB:-2}
  ((per_job_gb < 1)) && per_job_gb=1

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
  local jobs omp_threads
  jobs="$(parallel_calculate_jobs)"

  export MAX_JOBS="${MAX_JOBS:-$jobs}"
  export NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
  export PARALLEL_LEVEL="${PARALLEL_LEVEL:-$MAX_JOBS}"
  export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
  export NINJAFLAGS="${NINJAFLAGS:--j$MAX_JOBS}"
  export MAKEFLAGS="${MAKEFLAGS:--jobs=$MAX_JOBS --output-sync=target}"
  export GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"

  omp_threads="${OMP_NUM_THREADS:-$MAX_JOBS}"
  export OMP_NUM_THREADS="$omp_threads"
  export MKL_NUM_THREADS="${MKL_NUM_THREADS:-$omp_threads}"
  export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-$omp_threads}"
  export BLIS_NUM_THREADS="${BLIS_NUM_THREADS:-$omp_threads}"
  export NUMEXPR_MAX_THREADS="${NUMEXPR_MAX_THREADS:-$omp_threads}"
  export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-$MAX_JOBS}"

  # ccache defaults for faster rebuilds
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
  export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-time_macros,include_file_mtime}"
  mkdir -p "$CCACHE_DIR" 2>/dev/null || true
}

parallel_env_summary() {
  local mem_gb cores
  mem_gb=$(_parallel_mem_gb)
  cores=$(nproc --all 2>/dev/null || echo "unknown")
  echo "🧮 Parallel config -> jobs=$MAX_JOBS, cores=$cores, mem=${mem_gb}GiB"
  echo "    MAKEFLAGS=$MAKEFLAGS"
  echo "    NINJAFLAGS=$NINJAFLAGS"
  echo "    CMAKE_BUILD_PARALLEL_LEVEL=$CMAKE_BUILD_PARALLEL_LEVEL"
}
