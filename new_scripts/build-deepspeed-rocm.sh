#!/bin/bash
# ============================================
# DeepSpeed 0.16.2 with ROCm/HIP Support
# Benefit:  Distributed training, ZeRO optimization
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env-gfx1151.sh"

DS_VERSION="0.16.2"
BUILD_DIR="$HOME/mpg-builds/deepspeed"
WHEEL_DIR="$HOME/mpg-builds/wheels"

echo "============================================"
echo "Building DeepSpeed $DS_VERSION for ROCm"
echo "============================================"

# Verify PyTorch ROCm is installed
python -c "import torch; assert torch.cuda.is_available()" || {
    echo "ERROR: PyTorch with ROCm not detected."
    exit 1
}

mkdir -p "$BUILD_DIR" "$WHEEL_DIR"
cd "$BUILD_DIR"

# Clean previous build
rm -rf DeepSpeed

# Clone source
git clone --depth 1 --branch "v${DS_VERSION}" https://github.com/microsoft/DeepSpeed. git
cd DeepSpeed

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

# Apply gfx1151 patch if needed
# Some DeepSpeed ops need architecture detection fix
cat > gfx1151_patch.py << 'PYEOF'
import re
import glob

for f in glob.glob("csrc/**/*.cpp", recursive=True) + glob.glob("csrc/**/*.cu", recursive=True):
    with open(f, 'r') as file:
        content = file.read()
    # Add gfx1151 to supported architectures
    if 'gfx90a' in content and 'gfx1151' not in content:
        content = content.replace('gfx90a', 'gfx90a", "gfx1151')
        with open(f, 'w') as file:
            file. write(content)
        print(f"Patched: {f}")
PYEOF
python gfx1151_patch.py

# Build wheel
pip wheel . --no-deps --wheel-dir="$WHEEL_DIR"

# Install
pip install --force-reinstall "$WHEEL_DIR"/deepspeed-*.whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
import deepspeed
print(f'DeepSpeed version:  {deepspeed.__version__}')
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
echo "Wheel: $WHEEL_DIR/deepspeed-*. whl"