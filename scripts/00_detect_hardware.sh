#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Detecting hardware configuration..."

# Create build_config directory
mkdir -p build_config

# Detect CPU
CPU_MODEL=$(lscpu | grep -i "model name" | cut -d: -f2 | xargs)
CPU_CORES=$(lscpu | grep -i "^CPU(s):" | awk '{print $2}')
CPU_THREADS=$(lscpu | grep -i "Thread(s) per core" | awk '{print $4}')
CPU_ARCH=""

# Determine CPU microarchitecture (RYZEN AI MAX+ / Strix Halo is Zen 5)
if [[ "${CPU_MODEL^^}" == *"RYZEN AI MAX+"* ]] || [[ "${CPU_MODEL^^}" == *"ZEN 5"* ]]; then
    CPU_ARCH="znver5"
    echo "✅ Detected Zen 5 CPU architecture (znver5)"
elif [[ "$CPU_MODEL" == *"Zen 4"* ]]; then
    CPU_ARCH="znver4"
    echo "✅ Detected Zen 4 CPU architecture (znver4)"
else
    # Fallback based on CPU flags
    if lscpu | grep -q "avx512"; then
        CPU_ARCH="znver5"
        echo "⚠️  Unknown CPU model but AVX-512 detected, assuming znver5 (Strix Halo optimized)"
    else
        CPU_ARCH="x86-64-v3"
        echo "⚠️  Using generic x86-64-v3 CPU target"
    fi
fi

# Detect GPU via ROCm
GPU_ARCH=""
if command -v rocminfo &> /dev/null; then
    echo "Checking ROCm GPU..."
    ROCM_ARCH=$(rocminfo 2>/dev/null | grep -oP "gfx[0-9a-f]+" | head -1)
    if [[ -n "$ROCM_ARCH" ]]; then
        GPU_ARCH="$ROCM_ARCH"
        echo "✅ Detected ROCm GPU architecture: $GPU_ARCH"
    else
        echo "❌ ROCm installed but no GPU detected via rocminfo"
    fi
else
    # Check via PCI for AMD GPUs
    if lspci | grep -i "VGA.*AMD" &> /dev/null; then
        echo "⚠️  AMD GPU detected but ROCm not installed"
    fi
fi

# Write detected configuration
cat > build_config/hw_detected.env << EOF
# Auto-generated hardware detection
DETECTED_CPU_MODEL="$CPU_MODEL"
DETECTED_CPU_CORES=$CPU_CORES
DETECTED_CPU_THREADS=$CPU_THREADS
DETECTED_CPU_ARCH="$CPU_ARCH"
DETECTED_GPU_ARCH="$GPU_ARCH"
EOF

echo "✅ Hardware detection complete. Configuration saved to build_config/hw_detected.env"
cat build_config/hw_detected.env
