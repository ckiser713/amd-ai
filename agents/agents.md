# agents.md — AI Agent Guidelines for this Repo

This file tells **AI coding agents** (ChatGPT, Cursor, GitHub agents, etc.) how to work with this repo safely.

The goal is to keep this project:

- **ROCm-first** for the AMD Ryzen AI Max+ 395 + Radeon 8060S (gfx1151).
- **Deterministic & reproducible** across rebuilds.
- **Easy to extend** for future GPUs (new AMD dGPU, NVIDIA card, other hosts).

---

## 1. Repo purpose (for agents)

This repo is a **build system** for:

- PyTorch 2.9.1 (ROCm 7.1.1 + CPU)
- vLLM (ROCm when possible, CPU fallback)
- llama.cpp (CPU-optimized + HIP/ROCm experimental build)

The scripts are organized as small, composable phases under `scripts/` and assume:

- ROCm is installed on the host under `/opt/rocm`.
- Python 3.11 is available.
- The project-local virtualenv is at `./.venv` unless `VENV_DIR` is explicitly overridden.

Agents should treat this repo as a **tooling and infra** layer, not an application.

---

## 2. Canonical entrypoints

When reasoning about or editing this repo, agents should anchor on these scripts:

- `scripts/10_env_rocm_gfx1151.sh` — canonical ROCm env for gfx1151.
- `scripts/11_env_cpu_optimized.sh` — canonical CPU (znver4) flags & threading.
- `scripts/20_build_pytorch_rocm.sh` — **only** place to define PyTorch ROCm 2.9.1 build config.
- `scripts/21_build_pytorch_cpu.sh` — CPU-only PyTorch build.
- `scripts/30_build_vllm_rocm_or_cpu.sh` — vLLM build config and host PyTorch wheel selection.
- `scripts/40_build_llama_cpp_cpu.sh` / `scripts/41_build_llama_cpp_rocm.sh` — llama.cpp build configs.
- `scripts/60_run_vllm_docker.sh` — vLLM ROCm Docker integration.

**Rule:** if you need to change how something is built, change it in the **phase script** above, not ad-hoc in `kickoff.sh` or random helper snippets.

---

## 3. Agent roles (recommended)

### 3.1 Build Orchestrator

- **Focus:** High-level sequencing, new phases, integration of additional libraries (Triton, FlashAttention, HF Accelerate, etc.).
- **Scope examples:**
  - Add a new `scripts/3X_build_*.sh` for an extra library.
  - Wire that phase into `kickoff.sh` without breaking existing flows.
- **Must:**
  - Reuse `10_env_rocm_gfx1151.sh` / `11_env_cpu_optimized.sh` instead of duplicating env logic.
  - Keep new scripts repo-relative and idempotent.

### 3.2 ROCm / CUDA Specialist

- **Focus:** Low-level flags, HIP/CUDA build options, future GPU support.
- **Scope examples:**
  - Add a new `env_*` script for a discrete AMD GPU or NVIDIA card.
  - Extend vLLM / PyTorch builds to support new GFX or SM arches.
- **Must:**
  - Keep **gfx1151 + ROCm 7.1.1** as the default on this machine.
  - When adding CUDA, modify `12_env_nvidia_cuda_example.sh` and **do not** break ROCm paths.

### 3.3 Benchmark & Tuning Agent

- **Focus:** Perf tests, micro-benchmarks, and auto-tuning.
- **Scope examples:**
  - Extend `python/benchmark_pytorch.py`.
  - Add simple llama.cpp benchmark scripts under `python/` or `scripts/`.
- **Must:**
  - Keep benchmarks **optional** and separate from build scripts.
  - Never turn on heavy tests inside core build phases by default.

---

## 4. Guardrails & anti-patterns

Agents **must NOT**:

1. **Hard-code absolute paths** (e.g., `/home/username/...`) inside scripts.
   - Always derive paths from `ROOT_DIR` / `SCRIPT_DIR` as the existing scripts do.

2. **Change hardware targets silently.**
   - CPU: keep `znver4` as the default `-march` unless explicitly asked to support other CPUs.
   - GPU: keep `gfx1151` as the default ROCm target; if adding more, **append**, don’t replace.

3. **Downgrade ROCm, PyTorch, or vLLM versions** without an explicit reason in comments.
   - If a downgrade is necessary, add a comment near the change explaining **why** and what was tested.

4. **Mix build concerns with application logic.**
   - This repo is for **builds & infra** only; do not add end-user apps here.

5. **Introduce hidden state.**
   - Avoid scripts that depend on undocumented env vars.
   - If a script uses `FOO=... ./scripts/bar.sh`, document that in a comment / README snippet.

---

## 5. How to extend for new hardware (for agents)

When the user adds a new GPU (e.g., a discrete Radeon or an NVIDIA card):

1. **Create a new env script** under `scripts/`:
   - Example: `13_env_rocm_gfx12xx.sh` or `13_env_nvidia_rtx50xx.sh`.
   - Set the appropriate `ROCM_GFX_ARCH` or `CUDA_ARCH_FLAGS` there.

2. **Update build scripts** to **detect** the new hardware and select the right env script:
   - Add detection logic to `scripts/00_detect_hardware.sh`.
   - Let `20_build_pytorch_rocm.sh` or equivalent choose the env based on detection.

3. **Document the change** in `README.md`:
   - New section: “Multi-GPU / new hardware notes”.

Always keep **gfx1151** as a supported path and avoid breaking existing flows for the original machine.

---

## 6. How to operate safely in AI IDEs

When running inside Cursor / VS Code / GitHub agents:

- Prefer **small, surgical edits** to individual scripts over giant rewrites.
- After editing a script, update the relevant section in `README.md` if behavior changed.
- Propose new phases as new files (e.g., `scripts/3X_*`) instead of overloading old ones with many modes.

If in doubt, ask the user to confirm before:

- Changing default target architectures.
- Changing PyTorch / vLLM / ROCm major versions.
- Introducing entirely new runtime dependencies.

---

## 7. TL;DR for agents

- Treat `scripts/10_*`, `20_*`, `30_*`, `40_*`, `41_*`, `60_*` as the **source of truth**.
- Keep everything **repo-relative**, **ROCm-first**, and **znver4/gfx1151-aware**.
- When you extend, do it by **adding small, well-named scripts** and updating the docs, not by rewriting the entire system.

---

## 8. Cursor / IDE guardrails (best practices)

- Stay quiet by default: no IDE pop-ups or prompt notifications asking to edit or create files; apply the minimal change directly, or ask once in-text if explicit approval is needed.
- Keep diffs small and reversible; avoid sweeping refactors unless requested.
- Never assume absolute paths; operate repo-relative and keep pinned versions/targets unless the user approves a change.
- Avoid interactive commands in scripts; ensure non-interactive, repeatable runs (use `--depth=1` for git clone/fetch).
- Do not mix build infra with app logic; new helpers live under `scripts/` or `python/` with a clear purpose.
