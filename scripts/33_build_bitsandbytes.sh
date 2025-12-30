#!/bin/bash
# bitsandbytes 0.45.0 ROCm for gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env
ensure_numpy_from_artifacts

source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"
source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

# Activate virtual environment (project-local, repo-relative)
VENV_DIR="${VENV_DIR:-"$ROOT_DIR/.venv"}"
if [[ -f "$VENV_DIR/bin/activate" ]]; then
    source "$VENV_DIR/bin/activate"
fi

SRC_DIR="$ROOT_DIR/src/extras/bitsandbytes"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/bitsandbytes-*.whl 1> /dev/null 2>&1; then
    echo "✅ bitsandbytes already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building bitsandbytes 0.45.0 for ROCm"
echo "============================================"
parallel_env_summary

# ROCm fork
cd "$SRC_DIR"
rm -rf build dist

export BNB_ROCM_ARCH="gfx1151"
export ROCM_HOME=$ROCM_PATH
export HIP_PATH=$ROCM_PATH
export PYTORCH_ROCM_ARCH="gfx1151"

# Use Ninja for CMake builds
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
export CMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS:-} -D__HIP_PLATFORM_AMD__ -mwavefrontsize64 -DDISABLE_MFMA_GFX1151=1"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

# Apply MFMA guard patch for gfx1151 (RDNA3+ doesn't support MFMA)
echo "Applying MFMA guard patch for gfx1151..."
cat > gfx1151_mfma_guard.py << 'PYEOF'
import glob
import os

target_patterns = ["csrc/**/*.hip", "csrc/**/*.cu", "csrc/**/*.cpp"]
guard_code = """
#if defined(__gfx1151__) || defined(__gfx1100__)
#define BNB_DISABLE_MFMA 1
#endif
"""

patched = 0
for pattern in target_patterns:
    for filepath in glob.glob(pattern, recursive=True):
        try:
            with open(filepath, 'r') as f:
                content = f.read()
            if 'BNB_DISABLE_MFMA' in content:
                continue
            if '__builtin_amdgcn_mfma' in content or 'mfma_' in content:
                # Guard MFMA calls
                new_content = guard_code + content
                new_content = new_content.replace(
                    '__builtin_amdgcn_mfma',
                    '/* MFMA disabled for gfx1151 */ (void)0 && __builtin_amdgcn_mfma'
                )
                with open(filepath, 'w') as f:
                    f.write(new_content)
                print(f"Patched MFMA guards: {filepath}")
                patched += 1
        except Exception as e:
            print(f"Warning: {filepath}: {e}")
print(f"MFMA guard patch complete: {patched} files")
PYEOF
python gfx1151_mfma_guard.py || echo "⚠ MFMA patch returned non-zero, continuing..."

# Build wheel with explicit parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation -v

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/bitsandbytes-*.whl

# Verify (change directory to avoid importing from source tree)
cd "$ROOT_DIR"
python -c "
import bitsandbytes as bnb
print(f'bitsandbytes imported')
print(f'CUDA available: {bnb.cuda_setup.main.CUDASetup.get_instance().cuda_available}')
"

echo "=== bitsandbytes build complete ==="
