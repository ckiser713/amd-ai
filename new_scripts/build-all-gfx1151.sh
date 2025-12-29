#!/bin/bash
# MPG-1 Complete gfx1151 Build Pipeline
# Target: AMD Strix Halo 128GB, ROCm 7.1.1, Python 3.11
set -e

echo "=============================================="
echo "MPG-1 gfx1151 (Strix Halo) Build Pipeline"
echo "=============================================="

BUILD_ROOT="$HOME/mpg-builds"
WHEEL_DIR="$BUILD_ROOT/wheels"
LOG_DIR="$BUILD_ROOT/logs"
mkdir -p $BUILD_ROOT $WHEEL_DIR $LOG_DIR

# Source environment
source env-gfx1151.sh

# Timing
START_TIME=$(date +%s)

build_component() {
    local name=$1
    local script=$2
    echo ""
    echo ">>> Building:  $name"
    echo "    Log: $LOG_DIR/${name}. log"
    
    if bash $script > "$LOG_DIR/${name}.log" 2>&1; then
        echo "    ✅ $name complete"
    else
        echo "    ❌ $name FAILED - check log"
        exit 1
    fi
}

# Build order matters - dependencies first
echo ""
echo "=== Phase 1: Core ML Stack ==="
build_component "pytorch"      "build-pytorch.sh"
build_component "torchvision"  "build-torchvision-audio.sh"
build_component "triton"       "build-triton.sh"

echo ""
echo "=== Phase 2: Attention & Inference ==="
build_component "flash-attn"   "build-flash-attn.sh"
build_component "xformers"     "build-xformers.sh"
build_component "vllm"         "build-vllm.sh"
build_component "llama-cpp"    "build-llama-cpp.sh"

echo ""
echo "=== Phase 3: Quantization ==="
build_component "bitsandbytes" "build-bitsandbytes.sh"

echo ""
echo "=== Phase 4: Optional Optimizations ==="
# Uncomment if desired
# build_component "numpy-rocm"   "build-numpy-rocm.sh"

# Collect wheels
echo ""
echo "=== Collecting Wheels ==="
find $BUILD_ROOT -name "*.whl" -exec cp {} $WHEEL_DIR/ \;
ls -la $WHEEL_DIR/

# Timing
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
echo ""
echo "=============================================="
echo "Build Complete!"
echo "Duration: $((DURATION / 60)) minutes $((DURATION % 60)) seconds"
echo "Wheels:  $WHEEL_DIR/"
echo "=============================================="

# Create install script
cat > "$WHEEL_DIR/install-gfx1151-stack.sh" << 'EOF'
#!/bin/bash
# Install pre-built gfx1151 wheels
set -e
WHEEL_DIR="$(dirname "$0")"

pip install $WHEEL_DIR/torch-*. whl
pip install $WHEEL_DIR/torchvision-*.whl
pip install $WHEEL_DIR/torchaudio-*.whl
pip install $WHEEL_DIR/triton-*.whl
pip install $WHEEL_DIR/flash_attn-*.whl
pip install $WHEEL_DIR/xformers-*. whl
pip install $WHEEL_DIR/vllm-*.whl

echo "gfx1151 stack installed successfully"
python -c "import torch; print(f'PyTorch {torch.__version__} on {torch.cuda.get_device_name(0)}')"
EOF
chmod +x "$WHEEL_DIR/install-gfx1151-stack.sh"

echo ""
echo "To install on fresh system:"
echo "  $WHEEL_DIR/install-gfx1151-stack. sh"