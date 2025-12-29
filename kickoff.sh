#!/usr/bin/env bash
set -euo pipefail

# kickoff.sh — high-level orchestrator for the AMD ROCm AI build system.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo "=== AMD ROCm AI Build System kickoff ==="
echo "Root: $ROOT_DIR"
echo

SCRIPTS_DIR="$ROOT_DIR/scripts"

run_phase() {
  local script="$1"
  if [[ -x "$SCRIPTS_DIR/$script" ]]; then
    echo
    echo ">>> Running phase: $script"
    "$SCRIPTS_DIR/$script"
  else
    echo "⚠️  Skipping missing or non-executable script: $script"
  fi
}

# 0) Detect hardware (best effort)
run_phase "00_detect_hardware.sh"

# 1) System dependencies (safe to re-run; may require sudo)
run_phase "01_setup_system_dependencies.sh"

# 2) Python virtualenv under ./.venv
run_phase "02_install_python_env.sh"

# 3) PyTorch 2.9.1 (ROCm + CPU)
run_phase "20_build_pytorch_rocm.sh"

# 4) vLLM (ROCm if available, else CPU-only)
run_phase "30_build_vllm_rocm_or_cpu.sh"

# 5) llama.cpp builds (CPU + ROCm)
run_phase "40_build_llama_cpp_cpu.sh"
run_phase "41_build_llama_cpp_rocm.sh"

echo
echo "=== kickoff complete ==="
echo "Check 'wheels/', 'src/', and 'build_config/' for artifacts and logs."
