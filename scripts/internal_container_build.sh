#!/usr/bin/env bash
# scripts/internal_container_build.sh
set -e
source scripts/parallel_env.sh
export IGNORE_LOCKS=1

# Ensure we have the environment variables we expect
echo ">>> Internal Build: Max Jobs=$MAX_JOBS, Mode=$PARALLEL_MODE"

ARTIFACTS_DIR="/app/artifacts"

# Pre-build cleanup: Remove stale CMake caches from host builds
# These cause path mismatch errors when building in Docker with mounted source volumes
echo ">>> Cleaning stale CMake caches from source directories..."
for src_dir in /app/src/pytorch /app/src/extras/*; do
    if [[ -d "$src_dir" ]]; then
        rm -rf "$src_dir/build/aotriton" 2>/dev/null || true
        rm -rf "$src_dir/build/CMakeCache.txt" 2>/dev/null || true
        rm -rf "$src_dir/build/CMakeFiles" 2>/dev/null || true
        rm -f "$src_dir/CMakeCache.txt" 2>/dev/null || true
        rm -rf "$src_dir/CMakeFiles" 2>/dev/null || true
    fi
done
echo ">>> CMake cache cleanup complete"

# Helper: Install existing wheels from artifacts if they exist
install_if_exists() {
    local pattern="$1"
    if ls "$ARTIFACTS_DIR"/$pattern 1> /dev/null 2>&1; then
        echo ">>> Installing existing artifact: $pattern"
        pip install --force-reinstall --no-deps "$ARTIFACTS_DIR"/$pattern || true
    fi
}

# 0. Setup Python Environment inside container
# if [[ -f scripts/02_install_python_env.sh ]]; then
#     ./scripts/02_install_python_env.sh
# fi

# Apply dependency allowlist patches before build
echo ">>> Applying gfx1151 dependency allowlist patches..."
python3 /app/scripts/patch_dependency_allowlists.py || echo "⚠ Allowlist patch skipped"

# 1. Build NumPy FIRST (Base dependency for PyTorch, Triton, etc.)
ensure_numpy_from_artifacts
./scripts/24_build_numpy_rocm.sh

# 2. Build/Install Core Infrastructure (Needs NumPy)
# 2. Build/Install Core Infrastructure (Needs NumPy)
install_if_exists "torch-*.whl"
./scripts/20_build_pytorch_rocm.sh

echo ">>> Verifying PyTorch 2.9.1 artifact exists..."
ls -lh "$ARTIFACTS_DIR"/torch-2.9.1*.whl || { echo "❌ PyTorch 2.9.1 artifact missing after build!"; exit 1; }

install_if_exists "triton-*.whl"
./scripts/22_build_triton_rocm.sh

# 3. Build Pillow-SIMD (Optional but recommended before Vision)
install_if_exists "pillow-*.whl"
./scripts/39_build_pillow_simd.sh

# 4. Build downstream ML libraries
install_if_exists "torchvision-*.whl"
install_if_exists "torchaudio-*.whl"
./scripts/23_build_torchvision_audio.sh

# 5. Build remaining ML libraries
./scripts/31_build_flash_attn.sh
./scripts/32_build_xformers.sh
./scripts/33_build_bitsandbytes.sh
./scripts/34_build_deepspeed_rocm.sh
./scripts/35_build_onnxruntime_rocm.sh
./scripts/36_build_cupy_rocm.sh
./scripts/37_build_faiss_rocm.sh
./scripts/38_build_opencv_rocm.sh
./scripts/30_build_vllm_rocm_or_cpu.sh
./scripts/42_build_llama_cpp_b7551.sh

# 6. Generate stack installer
if [[ -f scripts/internal_gen_stack.sh ]]; then
    ./scripts/internal_gen_stack.sh
else
    echo "Warning: scripts/internal_gen_stack.sh not found, skipping installer generation."
fi
