#!/bin/bash
# scripts/80_run_complete_build_docker.sh
# Orchestrates the entire project build inside a clean ROCm Docker container.

set -e

# Repository Root Detection
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "=== AMD AI Builder: Initializing Docker Infrastructure ==="

# Step A: Define & Build the Builder Image
echo "Building amd-ai-builder:local..."
docker build -t amd-ai-builder:local -f - . <<EOF
FROM rocm/dev-ubuntu-24.04:7.1.1-complete

# Avoid interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Install System Dependencies (Python 3.11 explicitly)
RUN apt-get update && apt-get install -y \
    python3.11 \
    python3.11-venv \
    python3.11-dev \
    python3-pip \
    git \
    cmake \
    ninja-build \
    build-essential \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Set Environment Variables
ENV ROCM_PATH=/opt/rocm
ENV PATH=\$ROCM_PATH/bin:\$PATH

WORKDIR /app
EOF

echo "=== AMD AI Builder: Starting Containerized Build Pipeline ==="

# Step B: Execute the Build Pipeline
# Note: Using a single bash -c command string as requested.
docker run --rm \
    -v "$ROOT_DIR:/app" \
    --user "$(id -u):$(id -g)" \
    -e ROCM_PATH=/opt/rocm \
    -e HOME=/tmp \
    amd-ai-builder:local \
    bash -c "
        set -e
        echo 'Starting Build Pipeline inside Container...'
        
        # 1. Install/Verify Python Environment
        # We run it here to ensure the venv is created/checked inside the container context
        ./scripts/02_install_python_env.sh

        # 2. Parallel Prefetch
        ./scripts/05_git_parallel_prefetch.sh

        # 3. Compile Scripts In Order
        ./scripts/22_build_triton_rocm.sh
        ./scripts/23_build_torchvision_audio.sh
        ./scripts/24_build_numpy_rocm.sh
        ./scripts/31_build_flash_attn.sh
        ./scripts/32_build_xformers.sh
        ./scripts/33_build_bitsandbytes.sh
        ./scripts/34_build_deepspeed_rocm.sh
        ./scripts/35_build_onnxruntime_rocm.sh
        ./scripts/36_build_cupy_rocm.sh
        ./scripts/37_build_faiss_rocm.sh
        ./scripts/38_build_opencv_rocm.sh
        ./scripts/39_build_pillow_simd.sh
        ./scripts/42_build_llama_cpp_b7551.sh

        echo 'Build Pipeline Completed Successfully!'
    "

# Step C: Verification
echo "=== AMD AI Builder: Host Verification ==="
if [ -d "artifacts" ]; then
    echo "Contents of artifacts/ directory:"
    ls -R artifacts/
else
    echo "Warning: artifacts/ directory not found. Build might have failed or not produced artifacts."
fi

echo "Done."
