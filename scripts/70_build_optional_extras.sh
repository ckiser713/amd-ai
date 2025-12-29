#!/bin/bash
# ============================================
# MPG-1 Optional Dependencies - Complete Build
# Target: AMD Strix Halo gfx1151, Python 3.11
# ============================================
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/10_env_rocm_gfx1151.sh"

BUILD_ROOT="$ROOT_DIR/src/extras"
WHEEL_DIR="$ROOT_DIR/artifacts"
LOG_DIR="$ROOT_DIR/logs"

mkdir -p "$BUILD_ROOT" "$WHEEL_DIR" "$LOG_DIR"

# Timing
START_TIME=$(date +%s)

echo "============================================"
echo "MPG-1 Optional Dependencies Build"
echo "============================================"
echo "Build Root: $BUILD_ROOT"
echo "Wheel Dir:  $WHEEL_DIR"
echo "Log Dir:    $LOG_DIR"
echo ""

# Build function
build_component() {
    local name=$1
    local script=$2
    local required=${3:-false}
    
    echo ""
    echo ">>> Building: $name"
    echo "    Script: $script"
    echo "    Log: $LOG_DIR/${name}.log"
    
    # We look for scripts in the canonical scripts/ directory now
    local scripts_dir="$ROOT_DIR/scripts"
    
    if [ ! -f "${scripts_dir}/${script}" ]; then
        echo "    ⚠️ Script not found: ${scripts_dir}/${script}"
        return 1
    fi
    
    if bash "${scripts_dir}/${script}" > "$LOG_DIR/${name}.log" 2>&1; then
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

build_component "numpy-rocm" "24_build_numpy_rocm.sh" && RESULTS["numpy-rocm"]="✅" || RESULTS["numpy-rocm"]="❌"
# Scipy is usually standard, but if we had a script it would be here. Assuming logic from original had it, 
# but I don't see a source file for scipy-rocm in the original new_scripts list provided. 
# Leaving commented out unless added.
# build_component "scipy-rocm" "build-scipy-rocm.sh" && RESULTS["scipy-rocm"]="✅" || RESULTS["scipy-rocm"]="❌"

# ============================================
# Phase 2: ML Acceleration
# ============================================
echo ""
echo "=== Phase 2: ML Acceleration ==="

build_component "onnxruntime-rocm" "35_build_onnxruntime_rocm.sh" && RESULTS["onnxruntime"]="✅" || RESULTS["onnxruntime"]="❌"
build_component "deepspeed-rocm" "34_build_deepspeed_rocm.sh" && RESULTS["deepspeed"]="✅" || RESULTS["deepspeed"]="❌"
build_component "cupy-rocm" "36_build_cupy_rocm.sh" && RESULTS["cupy"]="✅" || RESULTS["cupy"]="❌"

# ============================================
# Phase 3: Tokenization & Processing
# ============================================
echo ""
echo "=== Phase 3: Tokenization & Processing ==="

# tokenizers logic wasn't in list, skipping unless requested
build_component "pillow-simd" "39_build_pillow_simd.sh" && RESULTS["pillow-simd"]="✅" || RESULTS["pillow-simd"]="❌"

build_component "flash-attn" "31_build_flash_attn.sh" && RESULTS["flash-attn"]="✅" || RESULTS["flash-attn"]="❌"
build_component "xformers" "32_build_xformers.sh" && RESULTS["xformers"]="✅" || RESULTS["xformers"]="❌"
build_component "bitsandbytes" "33_build_bitsandbytes.sh" && RESULTS["bitsandbytes"]="✅" || RESULTS["bitsandbytes"]="❌"

# ============================================
# Phase 4: Computer Vision & Search
# ============================================
echo ""
echo "=== Phase 4: Computer Vision & Search ==="

build_component "opencv-rocm" "38_build_opencv_rocm.sh" && RESULTS["opencv"]="✅" || RESULTS["opencv"]="❌"
build_component "faiss-rocm" "37_build_faiss_rocm.sh" && RESULTS["faiss"]="✅" || RESULTS["faiss"]="❌"
build_component "torchvision-audio" "23_build_torchvision_audio.sh" && RESULTS["torchvision"]="✅" || RESULTS["torchvision"]="❌"

# ============================================
# Phase 5: Alternative Triton
# ============================================
echo ""
echo "=== Phase 5: Alternative Triton ==="

build_component "pytorch-triton-rocm" "22_build_triton_rocm.sh" && RESULTS["triton-alt"]="✅" || RESULTS["triton-alt"]="❌"

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
echo "Wheels in $WHEEL_DIR:"
ls -la "$WHEEL_DIR"/*.whl 2>/dev/null || echo "  No wheels found"

echo ""
echo "Log files in $LOG_DIR:"
ls -la "$LOG_DIR"/*.log 2>/dev/null | tail -20

echo ""
echo "============================================"
echo "Build Complete!"
echo "============================================"
