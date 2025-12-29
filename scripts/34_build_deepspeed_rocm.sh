#!/bin/bash
# ============================================
# DeepSpeed 0.16.2 with ROCm/HIP Support
# Benefit: Distributed training, ZeRO optimization
# Optimized for AMD Strix Halo 395+MAX 128GB
# ============================================
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env

source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"
source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

# Activate virtual environment (project-local, repo-relative)
VENV_DIR="${VENV_DIR:-"$ROOT_DIR/.venv"}"
if [[ -f "$VENV_DIR/bin/activate" ]]; then
    source "$VENV_DIR/bin/activate"
fi

SRC_DIR="$ROOT_DIR/src/extras/deepspeed"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/deepspeed-*.whl 1> /dev/null 2>&1; then
    echo "✅ DeepSpeed already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building DeepSpeed 0.16.2 for ROCm"
echo "============================================"
parallel_env_summary

# Verify PyTorch ROCm is installed
python -c "import torch; assert torch.cuda.is_available()" || {
    echo "ERROR: PyTorch with ROCm not detected."
    exit 1
}

cd "$SRC_DIR"
rm -rf build dist

# Set ROCm environment
export DS_BUILD_OPS=1
export DS_BUILD_AIO=1
export DS_BUILD_FUSED_ADAM=1
export DS_BUILD_FUSED_LAMB=1
export DS_BUILD_CPU_ADAM=1
export DS_BUILD_CPU_LION=1
export DS_BUILD_TRANSFORMER=1
export DS_BUILD_TRANSFORMER_INFERENCE=1
export DS_BUILD_STOCHASTIC_TRANSFORMER=1
export DS_BUILD_UTILS=1
export DS_BUILD_CCL_COMM=0
export DS_BUILD_EVOFORMER_ATTN=0

# ROCm specific
export ROCM_HOME="${ROCM_PATH}"
export HIP_HOME="${ROCM_PATH}"
export PYTORCH_ROCM_ARCH="gfx1151"
export DS_ACCELERATOR="cuda"  # DeepSpeed uses CUDA API names

# Use Ninja for CMake builds
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

# Apply gfx1151 patch
# Some DeepSpeed ops need architecture detection fix
cat > gfx1151_patch.py << 'PYEOF'
import glob

for f in glob.glob("csrc/**/*.cpp", recursive=True) + glob.glob("csrc/**/*.cu", recursive=True):
    with open(f, 'r') as file:
        content = file.read()
    # Add gfx1151 to supported architectures
    if 'gfx90a' in content and 'gfx1151' not in content:
        content = content.replace('gfx90a', 'gfx90a", "gfx1151')
        with open(f, 'w') as file:
            file.write(content)
        print(f"Patched: {f}")
PYEOF
python gfx1151_patch.py

# Build wheel
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR"

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/deepspeed-*.whl

# Verify (change directory to avoid importing from source tree)
cd "$ROOT_DIR"
echo ""
echo "=== Verification ==="
python -c "
import deepspeed
print(f'DeepSpeed version: {deepspeed.__version__}')
print(f'CUDA available: {deepspeed.accelerator.get_accelerator().is_available()}')
print(f'Device name: {deepspeed.accelerator.get_accelerator().device_name()}')

# Report ops status
from deepspeed.ops.op_builder import ALL_OPS
print()
print('Ops status:')
for op_name, builder in ALL_OPS.items():
    try:
        status = '✅' if builder.is_compatible() else '❌'
    except:
        status = '⚠️'
    print(f'  {op_name}: {status}')
"

echo ""
echo "=== DeepSpeed build complete ==="
echo "Wheel: $ARTIFACTS_DIR/deepspeed-*.whl"
