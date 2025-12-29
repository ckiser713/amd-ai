# AMD ROCm AI Build System (Ryzen AI Max+ 395 / gfx1151)

This repo is a **scripted build workspace** for compiling and running a modern AI stack on an AMD Ryzen AI Max+ 395 (Zen 4) with an integrated Radeon 8060S GPU exposed as **gfx1151** via ROCm.

It focuses on three core components:

- **PyTorch 2.9.1** (ROCm 7.1.1 + CPU).
- **vLLM** (GPU first, CPU fallback).
- **llama.cpp** (CPU-optimized and experimental HIP/ROCm build).

The scripts are designed to be:

- **Repo-relative** (no hard-coded home paths).
- **Hardware-aware** (znver4 CPU, gfx1151 GPU).
- **Re-runnable** (clean rebuilds, cached wheels, reproducible phases).
- **Agent-friendly** (easy for ChatGPT / Cursor / other AIs to reason about and extend).

---

## 1. Host requirements

Minimum assumptions:

- Ubuntu 24.04 (or close) with a recent kernel.
- ROCm **7.1.1** installed on the host under `/opt/rocm` (HIP, rocBLAS, MIOpen, RCCL).
- Python 3.11 available on the host.
- Docker (optional) for vLLM container experiments.
- Nix (optional) if you want the pinned dev shell.

The scripts **do not** install ROCm themselves; they assume the ROCm stack is already present.

---

## 2. Layout overview

```text
amd-ai-build-system-v2/
  kickoff.sh                 # Orchestrator (optional, runs phases in order)

  flake.nix                  # Nix devShell for deterministic toolchain

  scripts/
    00_detect_hardware.sh    # Detect CPU / GPU and record summary
    01_setup_system_dependencies.sh
    02_install_python_env.sh # Creates .venv under repo root
    05_git_parallel_prefetch.sh # Parallel fetch/init for git repos with submodules

    10_env_rocm_gfx1151.sh   # ROCm env for gfx1151
    11_env_cpu_optimized.sh  # CPU env (znver4, OpenBLAS, threads)
    12_env_nvidia_cuda_example.sh  # Template for future CUDA hosts

    20_build_pytorch_rocm.sh # Build PyTorch 2.9.1 (ROCm + CPU)
    21_build_pytorch_cpu.sh  # Build PyTorch 2.9.1 (CPU-only)

    30_build_vllm_rocm_or_cpu.sh   # Build vLLM; ROCm if possible, else CPU
    40_build_llama_cpp_cpu.sh      # llama.cpp CPU-optimized build
    41_build_llama_cpp_rocm.sh     # llama.cpp HIP/ROCm build (gfx1151)

    50_run_llama_server_example.sh # Sample llama.cpp server run
    60_run_vllm_docker.sh          # vLLM ROCm Docker helper

    99_optimize_build_env.sh       # Misc tuning helpers

  python/
    benchmark_pytorch.py      # Simple sanity / perf checks

  src/
    pytorch/                  # PyTorch source tree (ROCm)
    pytorch-cpu/              # PyTorch source tree (CPU-only, optional)
    vllm/                     # vLLM source tree
    llama.cpp/                # llama.cpp source tree

  wheels/                     # Cached wheels (torch, vllm, etc.)
  RoCompNew/                  # Build artifacts / summaries (legacy path)
  build_config/               # Build metadata / logs
  agents/                     # Agent-side helper scripts & tooling

  README.md
  agents.md                   # Roles & guardrails for AI agents
```

> All paths are **repo-relative** so the whole folder is safe to move or copy.

---

## 3. Quick start: bare-metal flow

From the repo root:

```bash
# 0) Make sure scripts are executable
chmod +x kickoff.sh scripts/*.sh

# 1) One-time system deps (build-essential, cmake, etc.)
./scripts/01_setup_system_dependencies.sh

# 2) Python 3.11 virtualenv under ./.venv
./scripts/02_install_python_env.sh

# 3) Build PyTorch 2.9.1 (ROCm + CPU, gfx1151 only)
./scripts/20_build_pytorch_rocm.sh

# 4) Build vLLM (ROCm if ROCm 7.1.x + GPU is detected, else CPU-only)
./scripts/30_build_vllm_rocm_or_cpu.sh

# 5) Build llama.cpp both ways (optional; pick one or both)
./scripts/40_build_llama_cpp_cpu.sh
./scripts/41_build_llama_cpp_rocm.sh
```

Or use:

```bash
./kickoff.sh
```

to run the phases sequentially.

---

## 4. Quick start: Nix dev shell

If you have Nix installed:

```bash
# From repo root
nix develop .#gmktec-rocm-dev

# Inside dev shell:
./scripts/02_install_python_env.sh
./scripts/20_build_pytorch_rocm.sh
./scripts/30_build_vllm_rocm_or_cpu.sh
./scripts/41_build_llama_cpp_rocm.sh
```

The devShell pins the build toolchain (git, cmake, ninja, gcc, Python 3.11, etc.) while still using the **host ROCm** under `/opt/rocm`.

---

## 5. vLLM: host build vs Docker

### 5.1 Host vLLM build

The host build uses your custom PyTorch 2.9.x wheels:

- `scripts/30_build_vllm_rocm_or_cpu.sh`:
  - Detects ROCm 7.1.x + `gfx1151` and prefers a **ROCm build**.
  - Falls back to **CPU-only** if ROCm is missing or incompatible.
  - Looks for a local `torch-2.9.*cp311*.whl` under `./wheels/` and force-reinstalls it before building vLLM.

After a successful run you can import vLLM from the `.venv` Python and run CLI or programmatic inference.

### 5.2 vLLM via ROCm Docker

To experiment with AMD’s ROCm-tuned vLLM images (or run a clean server):

```bash
# From repo root
./scripts/60_run_vllm_docker.sh
```

By default this will:

- Use `rocm/vllm-dev:nightly_main_20251128` (override with `VLLM_DOCKER_IMAGE=...`).
- Mount `./models/` on the host as `/app/model` in the container.
- Expose `/dev/kfd` and `/dev/dri` and join `video` / `render` groups.
- Start the OpenAI-compatible vLLM server on port `8000`.

If you just want an interactive shell inside the image:

```bash
SHELL_ONLY=1 ./scripts/60_run_vllm_docker.sh
```

---

## 6. llama.cpp usage notes

After building:

```bash
# CPU build
./src/llama.cpp/build/cpu/bin/llama   --model path/to/model.gguf   -p "Hello" -n 64

# HIP/ROCm build (experimental)
./src/llama.cpp/build/rocm/bin/llama   --model path/to/model.gguf   --gpu-layers 20   -p "Hello" -n 64
```

- CPU build uses `-march=znver4`, OpenBLAS, and AVX2/AVX-512/FMA where available.
- ROCm build uses HIPBLAS + unified memory (`LLAMA_HIP_UMA=ON`) to let the **gfx1151 APU** pull from system RAM.

`50_run_llama_server_example.sh` shows a simple HTTP/server mode example you can adapt.

---

## 7. Benchmarks & sanity checks

Use `python/benchmark_pytorch.py` as a template to verify:

- `torch.__version__` is 2.9.x.
- `torch.cuda.is_available()` is `True` on ROCm builds.
- Basic matmul and transformer-like workloads run without ROCm errors.

For deeper tuning, pin `OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, and examine CPU / GPU utilization with `htop`, `rocm-smi`, and `rocminfo`.

---

## 8. Where to point AI agents

See **`agents.md`** for how to instruct ChatGPT / Cursor / other AIs to:

- Extend the scripts safely.
- Add new hardware targets (future AMD/NVIDIA GPUs).
- Keep this repo reproducible and ROCm-first on your Strix Halo machine.
