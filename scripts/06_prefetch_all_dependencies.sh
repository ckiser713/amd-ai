#!/usr/bin/env bash
# scripts/06_prefetch_all_dependencies.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WHEELS_CACHE="$ROOT_DIR/wheels/cache"

echo "=== AMD AI Builder: Starting Comprehensive Prefetch Stage ==="

# 1. Git Repositories
echo ">>> Syncing Git repositories..."
bash "$SCRIPT_DIR/05_git_parallel_prefetch.sh"

# 2. Python Packages (Wheels)
echo ">>> Downloading Python wheels to $WHEELS_CACHE..."
mkdir -p "$WHEELS_CACHE"

# Core build dependencies
# Note: we use --only-binary=:all: to get wheels where possible
# and we target cp311 for the build environment
PACKAGES=(
    "pip" "setuptools" "wheel" "ninja" "cmake" "packaging" "pybind11" "swig"
    "meson" "meson-python" "cython"
    "transformers>=4.56.0" "accelerate" "setuptools-scm>=8" 
    "sentencepiece" "protobuf" "fastapi[standard]>=0.115.0" "aiohttp" "openai>=1.99.1" 
    "pydantic>=2.12.0" "tiktoken>=0.6.0" "lm-format-enforcer==0.11.3" 
    "diskcache==5.6.3" "compressed-tensors==0.12.2" "depyf==0.20.0" "gguf>=0.17.0" 
    "mistral_common[image]>=1.8.5" "opencv-python-headless>=4.11.0" "einops" 
    "numba==0.61.2" "ray[cgraph]>=2.48.0" "peft" "tensorizer==2.10.1" "timm>=1.0.17"
    "regex" "cachetools" "psutil" "requests>=2.26.0" "tqdm" "blake3" "py-cpuinfo" 
    "tokenizers>=0.21.1" "prometheus_client>=0.18.0" "pillow" 
    "prometheus-fastapi-instrumentator>=7.0.0" "llguidance>=1.3.0,<1.4.0" 
    "outlines_core==0.2.11" "lark==1.2.2" "xgrammar==0.1.27" "typing_extensions>=4.10" 
    "filelock>=3.16.1" "partial-json-parser" "pyzmq>=25.0.0" "msgspec" 
    "cloudpickle" "watchfiles" "python-json-logger" "scipy" "pybase64" "cbor2" 
    "setproctitle" "openai-harmony>=0.0.3" "anthropic==0.71.0" 
    "model-hosting-container-standards>=0.1.9,<1.0.0" "datasets" "pytest-asyncio" 
    "runai-model-streamer[s3,gcs]==0.15.0" "conch-triton-kernels==1.2.1"
    "pyyaml" "scipy" "sympy>=1.13.3" "mpmath"
)

# Download wheels
# We use --platform manylinux2014_x86_64 --python-version 311 
# to ensure we get wheels compatible with our build container
# We use --no-deps to prevent accidental pulls of standard torch/triton (CUDA)
python3.11 -m pip download \
    --dest "$WHEELS_CACHE" \
    --only-binary=:all: \
    --no-deps \
    --platform manylinux2014_x86_64 \
    --python-version 311 \
    "${PACKAGES[@]}"

# Special case for fastsafetensors (git dependency)
echo ">>> Fetching git-based Python dependencies..."
mkdir -p "$ROOT_DIR/src/deps"
if [[ ! -d "$ROOT_DIR/src/deps/fastsafetensors" ]]; then
    git clone https://github.com/foundation-model-stack/fastsafetensors.git "$ROOT_DIR/src/deps/fastsafetensors"
    cd "$ROOT_DIR/src/deps/fastsafetensors"
    git checkout d6f998a03432b2452f8de2bb5cefb5af9795d459
fi

# 3. External Binaries and C++ Headers (Triton)
echo ">>> Prefetching Triton C++ dependencies..."
TRITON_DEPS_DIR="$ROOT_DIR/wheels/cache/triton_deps"
mkdir -p "$TRITON_DEPS_DIR"

# pybind11 2.11.1
PYBIND11_URL="https://github.com/pybind/pybind11/archive/refs/tags/v2.11.1.tar.gz"
PYBIND11_DIR="$TRITON_DEPS_DIR/pybind11/pybind11-2.11.1"
if [[ ! -f "$PYBIND11_DIR/version.txt" ]]; then
    mkdir -p "$TRITON_DEPS_DIR/pybind11"
    curl -L "$PYBIND11_URL" -o "$TRITON_DEPS_DIR/pybind11/v2.11.1.tar.gz"
    tar -xzf "$TRITON_DEPS_DIR/pybind11/v2.11.1.tar.gz" -C "$TRITON_DEPS_DIR/pybind11"
    echo "$PYBIND11_URL" > "$PYBIND11_DIR/version.txt"
fi

# nlohmann/json 3.11.3
JSON_URL="https://github.com/nlohmann/json/releases/download/v3.11.3/include.zip"
JSON_DIR="$TRITON_DEPS_DIR/json"
if [[ ! -f "$JSON_DIR/version.txt" ]]; then
    mkdir -p "$JSON_DIR"
    curl -L "$JSON_URL" -o "$TRITON_DEPS_DIR/json/include.zip"
    unzip -q "$TRITON_DEPS_DIR/json/include.zip" -d "$JSON_DIR"
    echo "$JSON_URL" > "$JSON_DIR/version.txt"
fi

# Triton LLVM (optimized for Triton)
TRITON_LLVM_REV="10dc3a8e"
LLVM_NAME="llvm-${TRITON_LLVM_REV}-ubuntu-x64"
LLVM_URL="https://oaitriton.blob.core.windows.net/public/llvm-builds/${LLVM_NAME}.tar.gz"
LLVM_DIR="$TRITON_DEPS_DIR/llvm/$LLVM_NAME"
if [[ ! -f "$LLVM_DIR/version.txt" ]]; then
    mkdir -p "$TRITON_DEPS_DIR/llvm"
    curl -L "$LLVM_URL" -o "$TRITON_DEPS_DIR/llvm/${LLVM_NAME}.tar.gz"
    mkdir -p "$LLVM_DIR"
    tar -xzf "$TRITON_DEPS_DIR/llvm/${LLVM_NAME}.tar.gz" -C "$TRITON_DEPS_DIR/llvm"
    echo "$LLVM_URL" > "$LLVM_DIR/version.txt"
fi

echo "=== Prefetch Stage Complete ==="
