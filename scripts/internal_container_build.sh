#!/usr/bin/env bash
# scripts/internal_container_build.sh
set -e

echo 'Starting Build Pipeline inside Container...'
echo "Python Version: $(python3 --version)"
if [[ ! $(python3 --version) == *"3.11"* ]]; then
    echo "❌ Error: Python 3.11 is required but found $(python3 --version)"
    exit 1
fi

# 1. Install/Verify Python Environment
# Inside the container, we rely on the pre-installed Python 3.11 and the PIP_FIND_LINKS environment variable.
./scripts/02_install_python_env.sh

# 2. Parallel Prefetch (Skipped inside container as it requires internet)
echo ">>> Skipping git prefetch (already completed on host)..."

# 3. Compile Scripts In Order
# Skip PyTorch if artifact already exists
if [[ -f "artifacts/torch-2.9.1-cp311-cp311-linux_x86_64.whl" ]]; then
    echo "PyTorch wheel already exists in artifacts/, skipping build..."
    pip install --force-reinstall artifacts/torch-2.9.1-cp311-cp311-linux_x86_64.whl
else
    ./scripts/20_build_pytorch_rocm.sh
fi

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
./scripts/30_build_vllm_rocm_or_cpu.sh
./scripts/42_build_llama_cpp_b7551.sh

# 4. Generate stack installer
echo ">>> Generating install-gfx1151-stack.sh..."
cat > artifacts/install-gfx1151-stack.sh << 'EOF'
#!/usr/bin/env bash
set -e
echo "Installing Zenith MPG-1 Stack (gfx1151)..."
# Force reinstall of wheels in artifacts/
pip install --force-reinstall --no-deps artifacts/*.whl
echo "Done. Stack installed."
EOF
chmod +x artifacts/install-gfx1151-stack.sh

echo 'Build Pipeline Completed Successfully!'
