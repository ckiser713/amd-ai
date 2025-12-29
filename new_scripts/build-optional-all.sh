#!/bin/bash
# ============================================
# MPG-1 Optional Dependencies - Complete Build
# Target: AMD Strix Halo gfx1151, Python 3.11
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$HOME/mpg-builds"
WHEEL_DIR="$BUILD_ROOT/wheels"
LOG_DIR="$BUILD_ROOT/logs"

mkdir -p "$BUILD_ROOT" "$WHEEL_DIR" "$LOG_DIR"

# Source environment
source "${SCRIPT_DIR}/env-gfx1151.sh"

# Timing
START_TIME=$(date +%s)

echo "============================================"
echo "MPG-1 Optional Dependencies Build"
echo "============================================"
echo "Build Root: $BUILD_ROOT"
echo "Wheel Dir:   $WHEEL_DIR"
echo "Log Dir:    $LOG_DIR"
echo ""

# Build function
build_component() {
    local name=$1
    local script=$2
    local required=${3:-false}
    
    echo ""
    echo ">>> Building:  $name"
    echo "    Script: $script"
    echo "    Log: $LOG_DIR/${name}. log"
    
    if [ !  -f "${SCRIPT_DIR}/${script}" ]; then
        echo "    ⚠️  Script not found: ${script}"
        return 1
    fi
    
    if bash "${SCRIPT_DIR}/${script}" > "$LOG_DIR/${name}.log" 2>&1; then
        echo "    ✅ $name complete"
        return 0
    else
        echo "    ❌ $name FAILED"
        if [ "$required" = "true" ]; then
            echo "    FATAL: Required component failed"
            exit 1
        fi
        echo "    Continuing with other components..."
        return 1
    fi
}

# Track results
declare -A RESULTS

# ============================================
# Phase 1: Core Numeric Libraries
# ============================================
echo ""
echo "=== Phase 1: Core Numeric Libraries ==="

build_component "numpy-rocm" "build-numpy-rocm.sh" && RESULTS["numpy-rocm"]="✅" || RESULTS["numpy-rocm"]="❌"
build_component "scipy-rocm" "build-scipy-rocm.sh" && RESULTS["scipy-rocm"]="✅" || RESULTS["scipy-rocm"]="❌"

# ============================================
# Phase 2: ML Acceleration
# ============================================
echo ""
echo "=== Phase 2: ML Acceleration ==="

build_component "onnxruntime-rocm" "build-onnxruntime-rocm.sh" && RESULTS["onnxruntime"]="✅" || RESULTS["onnxruntime"]="❌"
build_component "deepspeed-rocm" "build-deepspeed-rocm. sh" && RESULTS["deepspeed"]="✅" || RESULTS["deepspeed"]="❌"
build_component "cupy-rocm" "build-cupy-rocm.sh" && RESULTS["cupy"]="✅" || RESULTS["cupy"]="❌"

# ============================================
# Phase 3: Tokenization & Processing
# ============================================
echo ""
echo "=== Phase 3: Tokenization & Processing ==="

build_component "tokenizers" "build-tokenizers.sh" && RESULTS["tokenizers"]="✅" || RESULTS["tokenizers"]="❌"
build_component "pillow-simd" "build-pillow-simd.sh" && RESULTS["pillow-simd"]="✅" || RESULTS["pillow-simd"]="❌"

# ============================================
# Phase 4: Computer Vision & Search
# ============================================
echo ""
echo "=== Phase 4: Computer Vision & Search ==="

build_component "opencv-rocm" "build-opencv-rocm.sh" && RESULTS["opencv"]="✅" || RESULTS["opencv"]="❌"
build_component "faiss-rocm" "build-faiss-rocm.sh" && RESULTS["faiss"]="✅" || RESULTS["faiss"]="❌"

# ============================================
# Phase 5: Alternative Triton
# ============================================
echo ""
echo "=== Phase 5: Alternative Triton ==="

build_component "pytorch-triton-rocm" "build-pytorch-triton-rocm.sh" && RESULTS["triton-alt"]="✅" || RESULTS["triton-alt"]="❌"

# ============================================
# Summary
# ============================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "============================================"
echo "Build Summary"
echo "============================================"
echo ""
echo "Duration: $((DURATION / 60)) minutes $((DURATION % 60)) seconds"
echo ""
echo "Results:"
for pkg in "${!RESULTS[@]}"; do
    printf "  %-20s %s\n" "$pkg" "${RESULTS[$pkg]}"
done

echo ""
echo "Wheels built:"
ls -la "$WHEEL_DIR"/*.whl 2>/dev/null || echo "  No wheels found"

echo ""
echo "Log files:"
ls -la "$LOG_DIR"/*.log 2>/dev/null | tail -20

# Create install script for optional deps
cat > "$WHEEL_DIR/install-optional-gfx1151.sh" << 'EOFINSTALL'
#!/bin/bash
# Install optional gfx1151-optimized packages
set -e
WHEEL_DIR="$(dirname "$0")"

echo "Installing optional gfx1151-optimized packages..."

# NumPy and SciPy (install first - foundational)
pip install --force-reinstall "$WHEEL_DIR"/numpy-*. whl 2>/dev/null && echo "✅ numpy" || echo "⚠️ numpy not found"
pip install --force-reinstall "$WHEEL_DIR"/scipy-*.whl 2>/dev/null && echo "✅ scipy" || echo "⚠️ scipy not found"

# ML Libraries
pip install --force-reinstall "$WHEEL_DIR"/onnxruntime*. whl 2>/dev/null && echo "✅ onnxruntime" || echo "⚠️ onnxruntime not found"
pip install --force-reinstall "$WHEEL_DIR"/deepspeed-*.whl 2>/dev/null && echo "✅ deepspeed" || echo "⚠️ deepspeed not found"
pip install --force-reinstall "$WHEEL_DIR"/cupy-*.whl 2>/dev/null && echo "✅ cupy" || echo "⚠️ cupy not found"

# Processing
pip install --force-reinstall "$WHEEL_DIR"/tokenizers-*.whl 2>/dev/null && echo "✅ tokenizers" || echo "⚠️ tokenizers not found"
pip install --force-reinstall --no-deps "$WHEEL_DIR"/pillow*. whl 2>/dev/null && echo "✅ pillow-simd" || echo "⚠️ pillow-simd not found"

# Search
pip install --force-reinstall "$WHEEL_DIR"/faiss*. whl 2>/dev/null && echo "✅ faiss" || echo "⚠️ faiss not found"

echo ""
echo "Optional packages installation complete"
EOFINSTALL
chmod +x "$WHEEL_DIR/install-optional-gfx1151.sh"

echo ""
echo "============================================"
echo "Build Complete!"
echo "============================================"
echo ""
echo "To install optional packages:"
echo "  $WHEEL_DIR/install-optional-gfx1151.sh"