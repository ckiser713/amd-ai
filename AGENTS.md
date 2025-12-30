AGENTS.md — AI Agent Operating Protocol

This document defines the strict operating procedures for AI coding agents (ChatGPT, Cursor, Claude, etc.) interacting with the amd-ai repository.

The primary goal is to maintain a high-performance AI stack optimized for the AMD Ryzen AI Max+ 395 (gfx1151 / znver5) with 128GB Unified Memory.

1. The Golden Rule of Installation

No Hidden PyPI Pulls: Agents must never allow pip install to pull a standard version of PyTorch or NumPy from the internet if a local ROCm-optimized version exists.

NumPy must be built and installed BEFORE PyTorch.

PyTorch must be installed BEFORE any ML dependency (vLLM, torchvision, etc.).

Artifacts Priority: Always use ensure_numpy_from_artifacts and install_if_exists logic to prioritize .whl files in the artifacts/ folder.

2. Mandatory Build & Dependency Order

When adding new libraries or modifying the build system, you MUST follow this sequence to prevent ROCm-optimized binaries from being overwritten by generic CPU/CUDA versions:

System Layer: 01_setup_system_dependencies.sh

Environment Layer: 02_install_python_env.sh (Base .venv)

Foundation Layer (NumPy): 24_build_numpy_rocm.sh (Must be first for BLAS/LAPACK optimization).

Core ML Layer (PyTorch): 20_build_pytorch_rocm.sh.

Strict Version: Only PyTorch 2.9.1 is supported.

Source: Must be built into artifacts/ and installed from there for all subsequent steps.

Intermediate Layer (Triton/Vision): 22_build_triton_rocm.sh and 23_build_torchvision_audio.sh.

Acceleration Layer: 31_build_flash_attn.sh, 32_build_xformers.sh, 33_build_bitsandbytes.sh.

Inference Layer: 30_build_vllm_rocm_or_cpu.sh or 41_build_llama_cpp_rocm.sh.

3. Strict PyTorch 2.9.1 Policy

Versioning: Never "upgrade" or "downgrade" any component version (specifically PyTorch 2.9.1) unless the user explicitly states a new version requirement.

Linking: When building downstream libraries, ensure PYTORCH_ROCM_ARCH="gfx1151" is exported.

Artifact-Only Installation: Downstream builds (e.g., vLLM) must point to the artifacts/ directory for their PyTorch requirement. If pip attempts to fetch PyTorch from an external index, the build is considered FAILED.

Verification: Every script that uses PyTorch should include a sanity check:

python -c "import torch; assert 'rocm' in torch.__version__.lower() or torch.version.hip, 'Optimized ROCm PyTorch NOT found!'"


## 4. The Masquerade Protocol (MANDATORY for gfx1151)

The AMD Strix Halo (gfx1151 / RDNA 3.5) operates under a **System-Wide Masquerade** due to firmware conflicts between Kernel 6.14+ and ROCm 7.1.1.

### A. Core Principle
> **Runtime identifies as gfx1100 (Radeon 7900 XTX); Build explicitly targets gfx1151.**

This is **NOT OPTIONAL**. Removing the masquerade will cause "Node-1 Memory Access Fault" errors.

### B. Environment Variables (NEVER REMOVE)
These exports in `scripts/10_env_rocm_gfx1151.sh` are **IMMUTABLE**:

```bash
# Runtime Masquerade (CRITICAL - DO NOT REMOVE)
export HSA_OVERRIDE_GFX_VERSION=11.0.0   # Fakes gfx1100 identity
export ROCBLAS_STREAM_ORDER_ALLOC=1      # Memory corruption fix
export HIP_FORCE_DEV_KERNARG=1           # Kernel launch latency fix

# ML Framework Stabilizers
export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 # Zero-copy for llama.cpp
export VLLM_ENFORCE_EAGER=true           # Bypass CUDA graph capture
export ROCSHMEM_DISABLE_MIXED_IPC=1      # IPC stabilizer

# Build Target (explicit gfx1151)
export PYTORCH_ROCM_ARCH=gfx1151
export HCC_AMDGPU_TARGET=gfx1151
```

### C. Wave32 Mandate (C++/HIP Patching)
RDNA 3.5 uses **Wave32** execution, not Wave64 like CDNA. When patching C++ or HIP code:

1. **LDS Constants**: Halve any values derived from warpSize (64 → 32).
2. **Compiler Flags**: Use `-DCK_TILE_WAVE_32=1` for xFormers/CK builds.
3. **MFMA Instructions**: Guard `__builtin_amdgcn_mfma` calls behind `#if !defined(__gfx1151__)`.

### D. Kernel 6.14+ Warning
Ubuntu 24.04 with **Kernel 6.14.0-1016-oem** has known firmware incompatibilities:
- "Node-1 Memory Access Fault" on bare gfx1151 execution
- ROCm 7.1.1 IPC failures without `ROCSHMEM_DISABLE_MIXED_IPC`
- Random GPU hangs without `HSA_OVERRIDE_GFX_VERSION`

**Treatment**: The masquerade variables above are the ONLY supported fix. Do not attempt native gfx1151 execution until ROCm 7.2+.

---

## 5. Hardware & Parallelism Constraints

Target CPU: znver5 (Zen 5). Use scripts/11_env_cpu_optimized.sh for CFLAGS.

Target GPU: gfx1151 (Strix Halo). Use scripts/10_env_rocm_gfx1151.sh.

Parallelism: Always source scripts/parallel_env.sh and respect MAX_JOBS.

6. Prohibited Actions & Anti-NVIDIA Policy

Strict Anti-NVIDIA/CUDA: No NVIDIA/CUDA dependencies, drivers, or toolkit elements should ever be added to the prefetch or build scripts. If a third-party library attempts to force a CUDA dependency, the build must be halted.

No pip install torch: This will pull a non-ROCm version. Use the local artifact.

No apt install of Python 3.12: This project is pinned to Python 3.11 for compatibility with ROCm 7.1.1.

No Silencing Errors: All build scripts must use set -e.

7. Escalation & Conflict Resolution

If a dependency conflict arises that cannot be solved by installing from the artifacts/ folder:

Do not attempt to solve the issue by adding external PyPI indices or upgrading core libraries.

Notify the User: Halt execution and prompt the user to provide all relevant logs to a secondary AI chat or developer to make a decision.

Check Compile List: If the path forward requires adding a library to the compile list, user confirmation is mandatory.

8. Logging & History Protocol (MANDATORY)

To build a searchable history of fixes and prevent recurring headaches, all agents must adhere to the following logging standard:

A. Triage Order

Action 1: Upon being notified of a build failure, the agent MUST view error.log.

Action 2: Sign into change.log (see workflow below).

B. The change.log Workflow

Every AI agent working on this repo MUST create or update change.log in the root directory.

Sign In: Generate a random AI name (e.g., Agent-Echo-9) and enter the current time and the error being addressed.

Analysis: Conduct a deep, end-to-end analysis of all files in question.

Fix: Apply the fix to the files.

Sign Out: Update the log with:

Detailed fix notes.

Recommendation for the user's next steps.

Timestamp of completion.

Format Template:

## [Random-AI-Name] | [YYYY-MM-DD HH:MM]
**Status**: IN_PROGRESS / FIXED
**Error Reported**: [Paste from error.log]
**Files Implicated**: [Path to files analyzed]
**Deep Dive Findings**: [Detailed technical analysis of the root cause]
**Applied Fix**: [Step-by-step logic change]
**Recommendation**: [What the user should do next]
**End Time**: [YYYY-MM-DD HH:MM]


9. Autonomous Build Agents (Silent Runner)

We provide a silent runner script (scripts/silent_build_runner.sh) for looping through repairs while consuming minimal tokens.

Behavior: Executes scripts/80_run_complete_build_docker.sh.

Output: Strictly prints "complete" on success or "failure" on error.

Failure Protocol: On failure, it populates error.log with brief but detailed context for the next repair cycle.

Looping: Agents should fix issues based on error.log and re-execute the silent runner until "complete" is returned.

10. Lock Protocol (MANDATORY)

The repository uses a "Lock & Track" system to prevent regressions on successful builds.

A. Lock Status Check

Before editing any shell script in scripts/, agents MUST check for a corresponding .lock file:

```bash
ls scripts/20_build_pytorch_rocm.sh.lock  # If exists, script is LOCKED
```

Or use the lock manager:

```bash
./scripts/lock_manager.sh --check scripts/20_build_pytorch_rocm.sh
```

B. Prohibited Actions

Agents are FORBIDDEN from:

1. Editing any script that has a .lock file without explicit user permission.

2. Removing or modifying .lock files without user approval.

3. Bypassing the lock check in build scripts.

C. Unlocking Procedure

If a user needs to modify a locked script, they must explicitly request:
> "Unlock script X"

The agent then runs:

```bash
./scripts/lock_manager.sh --unlock scripts/X.sh
```

D. Auto-Lock Behavior

All build scripts automatically lock themselves upon successful completion. This preserves the "Gold Standard" version that produced valid artifacts.

E. Dependency Matrix

The file build_config/dependency_matrix.json tracks:

1. Lock status of all build scripts.
2. Last successful build date.
3. Artifact produced by each script.
4. Upstream/downstream dependencies.

Agents should review this matrix before proposing changes that affect dependencies.
11. Documentation Standards & Creation Protocol (STRICT)

To prevent repository clutter and fragmentation, strict rules apply to the creation and management of documentation files.

A. Zero-Creation Policy
Agents are **STRICTLY PROHIBITED** from creating new Markdown (`.md`), Text (`.txt`), or log files autonomously.
* **Prohibited**: `update_log.md`, `fix_notes.md`, `error_summary.txt`, `temp_guide.md`.
* **Why**: Information fragmentation destroys knowledge retrieval.

B. Consolidation First Strategy
New information must be integrated into the existing canonical structure:
1.  **Architecture & High-Level Logic**: Update `README.md`.
2.  **Commands & Quick Steps**: Update `QUICK_REFERENCE.md`.
3.  **Deep Technical Details/Reference**: Update `COMPLETE_GUIDE.md`.
4.  **Agent Operating Rules**: Update `AGENTS.md`.
5.  **Build/Script Logic**: Add comments directly to the relevant `.sh` script.

C. Authorized Creation Flows
A new documentation file may ONLY be created under one condition:
* **Condition**: The user explicitly issues the command: *"Create a new document named [NAME]."*
* **Protocol**:
    1.  **Location**: Must be created in the repository root.
    2.  **Naming**: MUST use `SCREAMING_SNAKE_CASE.md` (e.g., `DEPLOYMENT_OPS.md`, `SECURITY_AUDIT.md`).
    3.  **Metadata**: The file must start with a `# Title` and a brief description of its specific scope.

D. Orphan Cleanup Authority
Agents are authorized and encouraged to:
1.  Identify "orphan" files (e.g., `notes.md`, `todo.txt`) that are not part of the canonical set.
2.  Merge their valuable content into `COMPLETE_GUIDE.md`.
3.  Delete the orphan file and log the action in `change.log`.
