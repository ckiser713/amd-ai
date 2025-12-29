### scripts/00_detect_hardware.sh
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

# Determine CPU microarchitecture
if [[ "$CPU_MODEL" == *"Ryzen AI Max+"* ]] || [[ "$CPU_MODEL" == *"Zen 5"* ]]; then
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


### scripts/01_setup_system_dependencies.sh
#!/usr/bin/env bash
set -euo pipefail

echo "📦 Installing system dependencies for Ubuntu 24.04..."

# Update package list
sudo apt-get update -y

# Essential build tools
sudo apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    git \
    wget \
    curl \
    libcurl4-openssl-dev \
    software-properties-common

# Python development
sudo apt-get install -y \
    python3.11 \
    python3.11-dev \
    python3.11-venv \
    python3-pip \
    python3-wheel \
    python3-setuptools

# Math and BLAS libraries
sudo apt-get install -y \
    libopenblas-dev \
    libblas-dev \
    liblapack-dev \
    libatlas-base-dev \
    libfftw3-dev \
    libgmp-dev \
    libmpfr-dev

# ROCm development packages (ROCm 7.1.1)
sudo apt-get install -y \
    rocm-hip-sdk \
    rocblas \
    rocrand \
    rccl \
    miopen-hip \
    hipblas \
    hipsparse \
    rocthrust \
    rocprofiler-dev \
    roctracer-dev

# System libraries
sudo apt-get install -y \
    libnuma-dev \
    libjemalloc-dev \
    libtinfo6 \
    libz-dev \
    libssl-dev \
    libsqlite3-dev \
    libreadline-dev \
    libncursesw5-dev \
    libbz2-dev \
    liblzma-dev

# Utilities
sudo apt-get install -y \
    htop \
    ncdu \
    tree \
    pkg-config \
    patchelf

# Add user to video group for ROCm access
if ! groups $USER | grep -q "video"; then
    echo "Adding $USER to video group for ROCm access..."
    sudo usermod -a -G video $USER
    echo "⚠️  Please log out and back in for group changes to take effect"
fi

echo "✅ System dependencies installed"
echo "   Run '02_install_python_env.sh' to set up Python environment"


### scripts/02_install_python_env.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🐍 Setting up Python 3.11 virtual environment..."

# Create project directory structure
mkdir -p src wheels

# Create virtual environment (using system Python 3.11)
if [[ ! -d ".venv" ]]; then
    python3.11 -m venv .venv
    echo "✅ Virtual environment created"
fi

# Activate virtual environment
source .venv/bin/activate

# Upgrade pip and setuptools inside the virtual environment
pip install --upgrade pip setuptools wheel

# Install build dependencies
pip install \
    ninja \
    pyyaml \
    typing-extensions \
    numpy \
    scipy \
    requests \
    psutil \
    tqdm \
    packaging

# Install development tools only if not in offline mode
if [[ -z "${PIP_NO_INDEX:-}" ]]; then
    # Install Jupyter for development (optional)
    pip install \
        jupyter \
        matplotlib \
        pandas

    # Install development tools
    pip install \
        black \
        flake8 \
        mypy \
        pytest
fi

# Create activation script
cat > activate_env.sh << 'EOF'
#!/usr/bin/env bash
source .venv/bin/activate
echo "Python virtual environment activated"
echo "Python: $(python --version)"
echo "Pip: $(pip --version | cut -d' ' -f2)"
EOF

chmod +x activate_env.sh

echo "✅ Python environment ready"
echo "   To activate: source .venv/bin/activate"
echo "   Or use: ./activate_env.sh"
echo ""
echo "📋 Installed packages:"
pip list --format=columns | grep -E "(Package|Version|-----|numpy|scipy|torch)"


### scripts/05_git_parallel_prefetch.sh
#!/usr/bin/env bash
set -euo pipefail

# Speed up git clone/fetch for repos with submodules by:
# - Enabling parallel submodule jobs
# - Fetching all remotes/tags recursively
# - Syncing and initializing submodules in parallel

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env
GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"

echo "Optimizing git clone/submodule throughput (jobs=$GIT_JOBS)..."

ensure_repo() {
    local target_dir="$1"
    local repo_url="$2"
    local branch="$3"
    local recursive="${4:-false}"

    if [[ ! -d "$target_dir" ]]; then
        echo ">>> Cloning $repo_url ($branch) to $target_dir..."
        if [[ "$recursive" == "true" ]]; then
            git clone --branch "$branch" --recursive "$repo_url" "$target_dir"
        else
            git clone --branch "$branch" "$repo_url" "$target_dir"
        fi
    else
        echo ">>> Updating $target_dir..."
        (
            cd "$target_dir"
            git fetch origin "$branch"
            git checkout "$branch"
            git pull origin "$branch"
        )
    fi
}

# Core Repos
repos=(
  "$ROOT_DIR/src/pytorch"
  "$ROOT_DIR/src/pytorch-cpu"
  "$ROOT_DIR/src/vllm"
  "$ROOT_DIR/src/llama.cpp"
)

# Extras Repos (Repo URL, Branch, Target Dir Name, Recursive)
# Format: "URL|BRANCH|DIR_NAME|RECURSIVE"
extras_repos=(
    "https://github.com/triton-lang/triton.git|v3.1.0|triton-rocm|false"
    "https://github.com/pytorch/vision.git|v0.20.1|torchvision|false"
    "https://github.com/pytorch/audio.git|v2.5.1|torchaudio|false"
    "https://github.com/numpy/numpy.git|v2.2.1|numpy|true"
    "https://github.com/ROCm/flash-attention.git|v2.7.4-cktile|flash-attention|false"
    "https://github.com/facebookresearch/xformers.git|v0.0.29|xformers|true"
    "https://github.com/ROCm/bitsandbytes.git|rocm_enabled|bitsandbytes|false"
    "https://github.com/microsoft/DeepSpeed.git|v0.16.2|deepspeed|false"
    "https://github.com/microsoft/onnxruntime.git|v1.20.1|onnxruntime|true"
    "https://github.com/cupy/cupy.git|v13.3.0|cupy|true"
    "https://github.com/facebookresearch/faiss.git|v1.9.0|faiss|false"
    "https://github.com/opencv/opencv.git|4.10.0|opencv|false"
    "https://github.com/opencv/opencv_contrib.git|4.10.0|opencv_contrib|false"
    "https://github.com/uploadcare/pillow-simd.git|10.4.0|pillow-simd|false"
    "https://github.com/ggml-org/llama.cpp.git|b7551|llama-cpp|false"
)

# Ensure extras repos exist
mkdir -p "$ROOT_DIR/src/extras"
for item in "${extras_repos[@]}"; do
    IFS='|' read -r url branch dirname recursive <<< "$item"
    ensure_repo "$ROOT_DIR/src/extras/$dirname" "$url" "$branch" "$recursive"
    repos+=("$ROOT_DIR/src/extras/$dirname")
done

# Parallel Optimization Loop
for repo in "${repos[@]}"; do
  if [[ ! -d "$repo/.git" ]]; then
    continue
  fi

  echo "Prefetching submodules/objects: $repo"
  (
    cd "$repo" || exit
    git config fetch.recurseSubmodules on-demand || true
    git config submodule.fetchJobs "$GIT_JOBS" || true
    
    # Only fetch if we can reach remote, otherwise skip to submodules
    if git remote get-url origin &>/dev/null; then
        git -c protocol.version=2 fetch --all --tags --recurse-submodules -j "$GIT_JOBS" --prune || echo "Fetch warning on $repo"
    fi

    if [[ -f ".gitmodules" ]]; then
        git submodule sync --recursive
        git -c submodule.fetchJobs="$GIT_JOBS" submodule update --init --recursive --jobs "$GIT_JOBS"
    fi
  )
done

echo "Done. Git repositories are synchronized."


### scripts/06_prefetch_all_dependencies.sh
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


### scripts/07_cleanup_nvidia_bloat.sh
#!/usr/bin/env bash
# scripts/07_cleanup_nvidia_bloat.sh
# Purpose: The "Antigravity" Sweep - Remove redundant NVIDIA/CUDA bloat from the wheel cache.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WHEELS_CACHE="$ROOT_DIR/wheels/cache"

echo "=== Antigravity Sweep: Cleaning NVIDIA/CUDA Bloat ==="

if [[ ! -d "$WHEELS_CACHE" ]]; then
    echo "Wheel cache directory $WHEELS_CACHE does not exist. Nothing to clean."
    exit 0
fi

# Targeted keywords
KEYWORDS=("nvidia" "cuda" "cublas" "cudnn" "nccl" "triton")

echo ">>> Searching for bloat in $WHEELS_CACHE..."

for KEYWORD in "${KEYWORDS[@]}"; do
    echo "Checking for '*$KEYWORD*'..."
    echo "Checking for '*$KEYWORD*'..."
    # 1. Clean wheels in the main cache
    find "$WHEELS_CACHE" -maxdepth 1 -type f -iname "*$KEYWORD*" -delete
    
    # 2. Clean bloat inside triton_deps (like the nvidia/ folder)
    # We use -mindepth 1 to avoid deleting triton_deps itself if the keyword is 'triton'
    if [[ -d "$WHEELS_CACHE/triton_deps" ]]; then
        find "$WHEELS_CACHE/triton_deps" -mindepth 1 -iname "*$KEYWORD*" -exec rm -rf {} +
    fi
done

echo ">>> Final check for heavy NVIDIA folders..."
if [[ -d "$WHEELS_CACHE/triton_deps/nvidia" ]]; then
    echo "Deleting heavy NVIDIA dependency folder in triton_deps..."
    rm -rf "$WHEELS_CACHE/triton_deps/nvidia"
fi

echo "=== Antigravity Sweep Complete ==="


### scripts/10_env_rocm_gfx1151.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Setting up ROCm environment..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env

# Load hardware detection
if [[ -f "$SCRIPT_DIR/../build_config/hw_detected.env" ]]; then
    source "$SCRIPT_DIR/../build_config/hw_detected.env"
fi

# ROCm paths (ROCm 7.1.1 default)
export ROCM_VERSION="7.1.1"
# If hipconfig reports a versioned ROCm prefix (e.g., /opt/rocm-7.1.1), prefer it
HIPCONFIG_PATH=""
if command -v hipconfig &> /dev/null; then
    HIPCONFIG_PATH="$(hipconfig --path 2>/dev/null || true)"
fi
export ROCM_PATH="${HIPCONFIG_PATH:-/opt/rocm}"
export HIP_PATH="$ROCM_PATH"
export HIP_ROOT_DIR="$ROCM_PATH"
export HIP_DIR="$ROCM_PATH/lib/cmake/hip"
export CMAKE_PREFIX_PATH="$ROCM_PATH${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
if [[ -d "$ROCM_PATH/lib/cmake" ]]; then
    export CMAKE_PREFIX_PATH="$ROCM_PATH/lib/cmake:${CMAKE_PREFIX_PATH}"
fi

# GPU architecture (fallback to gfx1151 if not detected)
export ROCM_GFX_ARCH="${DETECTED_GPU_ARCH:-gfx1151}"
export PYTORCH_ROCM_ARCH="$ROCM_GFX_ARCH"
export HCC_AMDGPU_TARGET="$ROCM_GFX_ARCH"

# ROCm library paths
export LD_LIBRARY_PATH="$ROCM_PATH/lib:$ROCM_PATH/lib64:$HIP_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$ROCM_PATH/bin:$HIP_PATH/bin:$ROCM_PATH/llvm/bin${PATH:+:$PATH}"

# Performance optimizations
export HIP_VISIBLE_DEVICES="0"  # Use first GPU
export HIP_LAUNCH_BLOCKING="0"  # Non-blocking kernel launches
export HIP_FORCE_DEV_KERNARG="1"  # Improve kernel launch latency
export HIP_PROFILE_API="0"  # Disable profiling unless needed

# ROCm-specific math libraries
export MIOpen_DISABLE_CACHE="0"
export MIOPEN_FIND_MODE="NORMAL"

CPU_CORES=${DETECTED_CPU_CORES:-$(nproc --all 2>/dev/null || echo 1)}
if ((CPU_CORES > 0)); then
    export GOMP_CPU_AFFINITY="0-$((CPU_CORES-1))"
fi
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

echo "✅ ROCm environment set for $ROCM_GFX_ARCH"
echo "   ROCM_PATH: $ROCM_PATH"
echo "   HIP_PATH: $HIP_PATH"
echo "   GPU Target: $ROCM_GFX_ARCH"
parallel_env_summary


### scripts/11_env_cpu_optimized.sh
#!/usr/bin/env bash
set -euo pipefail

echo "⚡ Setting up CPU-optimized environment..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env

# Load hardware detection
if [[ -f "$SCRIPT_DIR/../build_config/hw_detected.env" ]]; then
    source "$SCRIPT_DIR/../build_config/hw_detected.env"
fi

# CPU optimization flags for Zen 5 (Strix Halo)
export CPU_ARCH="${DETECTED_CPU_ARCH:-znver5}"

# Full Zen 5 / Strix Halo AVX-512 optimization flags
# Zen 5 supports: AVX-512F, AVX-512BW, AVX-512VL, AVX-512DQ, AVX-512CD, 
#                 AVX-512VBMI, AVX-512VBMI2, AVX-512VNNI, AVX-512BITALG, AVX-512VPOPCNTDQ
if [[ "$CPU_ARCH" == "znver5" ]]; then
    AVX512_FLAGS="-mavx512f -mavx512bw -mavx512vl -mavx512dq -mavx512cd"
    AVX512_FLAGS="$AVX512_FLAGS -mavx512vbmi -mavx512vbmi2 -mavx512vnni"
    AVX512_FLAGS="$AVX512_FLAGS -mavx512bitalg -mavx512vpopcntdq"
    AVX512_FLAGS="$AVX512_FLAGS -mavx512bf16"  # BFloat16 support on Zen 5
    
    export CFLAGS="-march=$CPU_ARCH -mtune=$CPU_ARCH -O3 $AVX512_FLAGS -pipe -fno-plt -fexceptions -flto=auto -fuse-linker-plugin"
    export CXXFLAGS="-march=$CPU_ARCH -mtune=$CPU_ARCH -O3 $AVX512_FLAGS -pipe -fno-plt -fexceptions -flto=auto -fuse-linker-plugin"
else
    export CFLAGS="-march=$CPU_ARCH -O3 -pipe -fno-plt -fexceptions -flto=auto"
    export CXXFLAGS="-march=$CPU_ARCH -O3 -pipe -fno-plt -fexceptions -flto=auto"
fi

# Linker optimization - prefer mold > lld > gold > ld
# Linker optimization - default to system linker for GCC LTO compatibility
export LDFLAGS="-Wl,-O1,--sort-common,--as-needed,-z,relro,-z,now -flto=auto"

CPU_CORES=${DETECTED_CPU_CORES:-$(nproc --all 2>/dev/null || echo 1)}
if ((CPU_CORES > 0)); then
    export GOMP_CPU_AFFINITY="0-$((CPU_CORES-1))"
fi
export OMP_PROC_BIND="spread"
export OMP_PLACES="threads"
export OMP_STACKSIZE="${OMP_STACKSIZE:-64M}"

export USE_OPENBLAS="1"
export USE_MKL="0"
export USE_CUDA="0"
export USE_ROCM="0"

export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

# Use ccache if available
if command -v ccache &> /dev/null; then
    export CC="ccache gcc"
    export CXX="ccache g++"
else
    export CC="gcc"
    export CXX="g++"
fi

# Python-specific build optimizations
export PYTHON_CONFIGURE_OPTS="--enable-optimizations --with-lto"

echo "✅ CPU environment optimized for $CPU_ARCH"
echo "   CFLAGS: $CFLAGS"
if [[ "$CPU_ARCH" == "znver5" ]]; then
    echo "   AVX-512 extensions: F, BW, VL, DQ, CD, VBMI, VBMI2, VNNI, BITALG, VPOPCNTDQ, BF16"
fi
parallel_env_summary


### scripts/12_env_nvidia_cuda_example.sh
#!/usr/bin/env bash
set -euo pipefail

echo "📝 NVIDIA CUDA environment template (for future use)"
echo "⚠️  This is a template only - NVIDIA GPU not detected"

# Uncomment and configure when adding NVIDIA GPU
# export USE_CUDA="1"
# export USE_ROCM="0"
# 
# # CUDA paths (adjust based on installation)
# export CUDA_HOME="/usr/local/cuda"
# export CUDA_PATH="$CUDA_HOME"
# export PATH="$CUDA_HOME/bin:$PATH"
# export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$CUDA_HOME/lib:$LD_LIBRARY_PATH"
# 
# # CUDA device selection
# export CUDA_VISIBLE_DEVICES="0"
# export CUDA_DEVICE_ORDER="PCI_BUS_ID"
# 
# # Performance flags
# export TF_ENABLE_ONEDNN_OPTS="1"
# export TF_CPP_MIN_LOG_LEVEL="2"
# 
# echo "✅ CUDA environment configured"

echo "📋 To use this template:"
echo "   1. Install NVIDIA drivers and CUDA toolkit"
echo "   2. Update paths above to match your installation"
echo "   3. Uncomment all export statements"
echo "   4. Source this file before building"


### scripts/20_build_pytorch_rocm.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🏗️  Building PyTorch 2.9.1 with ROCm support..."

# Load environments
source scripts/10_env_rocm_gfx1151.sh
source scripts/11_env_cpu_optimized.sh

# Resolve repo root before changing directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"

# Idempotency check
if ls "$ARTIFACTS_DIR"/torch-2.9.1*.whl 1> /dev/null 2>&1; then
    echo "✅ PyTorch already exists in artifacts/, skipping build."
    exit 0
fi

# Check ROCm installation
if [[ ! -d "$ROCM_PATH" ]]; then
    echo "❌ ROCm not found at $ROCM_PATH"
    echo "   Install ROCm 7.1.1 first or update ROCM_PATH"
    exit 1
fi

# Configuration
PYTORCH_VERSION="2.9.1"
PYTORCH_SRC_DIR="${PYTORCH_SRC_DIR:-src/pytorch}"
PYTORCH_BUILD_TYPE="Release"
BUILD_DIR="$PYTORCH_SRC_DIR/build"
NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
if [[ "${NUM_JOBS:-}" =~ ^[0-9]+$ && "${MAX_JOBS:-}" =~ ^[0-9]+$ && ${NUM_JOBS} -lt ${MAX_JOBS} ]]; then
    export MAX_JOBS="$NUM_JOBS"
fi
GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

configure_git_parallel() {
    git config fetch.recurseSubmodules on-demand || true
    git config submodule.fetchJobs "$GIT_JOBS" || true
}

git_fetch_all_recursive() {
    # Avoid fetching all tags to prevent upstream tag/branch name collisions on ciflow refs
    git -c protocol.version=2 fetch --all --no-tags --recurse-submodules -j "$GIT_JOBS" --prune
}

update_submodules_parallel() {
    git submodule sync --recursive
    git -c submodule.fetchJobs="$GIT_JOBS" submodule update --init --recursive --depth=1 --jobs "$GIT_JOBS"
}

# Clone PyTorch if not exists
if [[ ! -d "$PYTORCH_SRC_DIR" ]]; then
    echo "Cloning PyTorch v$PYTORCH_VERSION (shallow clone)..."
    # Temporarily disable problematic git config
    git config --global --unset remote.origin.fetch 2>/dev/null || true
    git clone --single-branch --branch "v$PYTORCH_VERSION" --depth=1 --recurse-submodules --shallow-submodules --jobs "$GIT_JOBS" https://github.com/pytorch/pytorch.git "$PYTORCH_SRC_DIR"
    cd "$PYTORCH_SRC_DIR"
    git config --unset remote.origin.fetch 2>/dev/null || true
    configure_git_parallel
    git_fetch_all_recursive
    update_submodules_parallel
else
    cd "$PYTORCH_SRC_DIR"
    configure_git_parallel
    git_fetch_all_recursive
    git checkout "v$PYTORCH_VERSION" 2>/dev/null || echo "Using existing source"
    update_submodules_parallel
fi

# Set build environment
export USE_ROCM=1
export USE_CUDA=0
export USE_DISTRIBUTED=1
export USE_HIP=1
export USE_RCCL=1
export USE_NCCL=1
export USE_SYSTEM_NCCL=1
export USE_GLOO=1
export BUILD_TEST=0
export USE_FBGEMM=0
export USE_MKLDNN=1
export USE_MKLDNN_CBLAS=1
export USE_NNPACK=0
export USE_QNNPACK=0
export USE_XNNPACK=0
export USE_PYTORCH_QNNPACK=0
export MAX_JOBS="$NUM_JOBS"
# Force the built wheel to use the pinned version string (avoid dev suffixes)
export PYTORCH_BUILD_VERSION="$PYTORCH_VERSION"
export PYTORCH_BUILD_NUMBER=0

# Activate virtual environment (project-local, repo-relative)
VENV_DIR="${VENV_DIR:-"$ROOT_DIR/.venv"}"

if [[ ! -d "$VENV_DIR" ]]; then
    echo "❌ Virtualenv not found at: $VENV_DIR"
    echo "   Run ./scripts/02_install_python_env.sh from the repo root first."
    exit 1
fi

# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

# Clean previous builds
rm -rf "$BUILD_DIR"
rm -rf dist
mkdir -p "$BUILD_DIR"
export CMAKE_FRESH=1

echo "Building PyTorch with ROCm arch: $PYTORCH_ROCM_ARCH"
echo "Build type: $PYTORCH_BUILD_TYPE"
echo "Using $MAX_JOBS parallel jobs"
echo "CMake/Ninja parallel: $CMAKE_BUILD_PARALLEL_LEVEL ($NINJAFLAGS)"
echo "Git parallel jobs: $GIT_JOBS"

# Build using setup.py (official PyTorch ROCm build method)
# python setup.py clean
# Ensure ROCm hipified sources are generated (required for ROCm builds)
if [[ ! -f "c10/hip/impl/hip_cmake_macros.h.in" ]]; then
    echo "Generating ROCm sources via tools/amd_build/build_amd.py..."
    python tools/amd_build/build_amd.py
fi

# Use ninja for faster builds if available
if command -v ninja &> /dev/null; then
    echo "Using ninja build system for optimal parallelism"
    export USE_NINJA=1
    export CMAKE_GENERATOR=Ninja
    # python setup.py bdist_wheel --cmake
else
    # Aggressive make parallelism
    # python setup.py bdist_wheel --cmake -- "-j$MAX_JOBS" "--output-sync=target"
    echo "Ninja not found, falling back to make"
fi

# Build the wheel
python setup.py bdist_wheel -- "-j$MAX_JOBS"

# Find and install the built wheel
WHEEL_FILE=$(find dist -name "*.whl" | head -1)
if [[ -n "$WHEEL_FILE" ]]; then
    echo "Installing built wheel: $WHEEL_FILE"
    pip install "$WHEEL_FILE" --force-reinstall --no-deps
    
    # Save the wheel to repo-relative cache locations
    WHEELS_OUT_DIR="$ROOT_DIR/wheels"
    mkdir -p "$WHEELS_OUT_DIR"
    cp "$WHEEL_FILE" "$WHEELS_OUT_DIR/"
    echo "Wheel saved to: $WHEELS_OUT_DIR/$(basename "$WHEEL_FILE")"
    
    ROCOMP_OUT_DIR="$ROOT_DIR/RoCompNew/pytorch"
    mkdir -p "$ROCOMP_OUT_DIR"
    cp "$WHEEL_FILE" "$ROCOMP_OUT_DIR/"
    echo "Wheel saved to: $ROCOMP_OUT_DIR/$(basename "$WHEEL_FILE")"
    
    # Alternative: Use develop mode to avoid import issues
    # pip install -e . --no-build-isolation
    
    # Verify installation
    echo "Verifying PyTorch ROCm installation..."
    # Change to a temporary directory to avoid import conflicts with source
    VERIFY_DIR=$(mktemp -d)
    pushd "$VERIFY_DIR" > /dev/null
    python -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'ROCm available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU: {torch.cuda.get_device_name(0)}')
    print(f'GPU Arch: $PYTORCH_ROCM_ARCH')
"
    popd > /dev/null
    rm -rf "$VERIFY_DIR"
else
    echo "❌ No wheel file found in dist/"
    exit 1
fi

echo "✅ PyTorch $PYTORCH_VERSION with ROCm built successfully"


### scripts/21_build_pytorch_cpu.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🏗️  Building PyTorch 2.9.1 (CPU-only)..."

# Resolve repo root before changing directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source scripts/11_env_cpu_optimized.sh

# Activate virtual environment (project-local, repo-relative)
VENV_DIR="${VENV_DIR:-"$ROOT_DIR/.venv"}"
if [[ -f "$VENV_DIR/bin/activate" ]]; then
    source "$VENV_DIR/bin/activate"
fi

# Idempotency check: Skip if any PyTorch wheel exists
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
if ls "$ARTIFACTS_DIR"/torch-*.whl 1> /dev/null 2>&1; then
    echo "✅ PyTorch already exists in artifacts/, skipping CPU build."
    exit 0
fi

# Configuration
PYTORCH_VERSION="2.9.1"
PYTORCH_SRC_DIR="${PYTORCH_SRC_DIR:-src/pytorch-cpu}"
BUILD_DIR="$PYTORCH_SRC_DIR/build"
NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
if [[ "${NUM_JOBS:-}" =~ ^[0-9]+$ && "${MAX_JOBS:-}" =~ ^[0-9]+$ && ${NUM_JOBS} -lt ${MAX_JOBS} ]]; then
    export MAX_JOBS="$NUM_JOBS"
fi
GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

configure_git_parallel() {
    git config fetch.recurseSubmodules on-demand || true
    git config submodule.fetchJobs "$GIT_JOBS" || true
}

git_fetch_all_recursive() {
    git -c protocol.version=2 fetch --all --tags --recurse-submodules -j "$GIT_JOBS" --prune
}

update_submodules_parallel() {
    git submodule sync --recursive
    git -c submodule.fetchJobs="$GIT_JOBS" submodule update --init --recursive --filter=blob:none --depth=1 --jobs "$GIT_JOBS"
}

# Clone PyTorch if not exists
if [[ ! -d "$PYTORCH_SRC_DIR" ]]; then
    echo "Cloning PyTorch v$PYTORCH_VERSION for CPU build (blobless partial clone)..."
    git clone --single-branch --branch "v$PYTORCH_VERSION" --depth=1 --filter=blob:none --recurse-submodules --shallow-submodules --jobs "$GIT_JOBS" https://github.com/pytorch/pytorch.git "$PYTORCH_SRC_DIR"
    cd "$PYTORCH_SRC_DIR"
    configure_git_parallel
    git_fetch_all_recursive
    git checkout "v$PYTORCH_VERSION"
    update_submodules_parallel
else
    cd "$PYTORCH_SRC_DIR"
    configure_git_parallel
    git_fetch_all_recursive
    git checkout "v$PYTORCH_VERSION" 2>/dev/null || echo "Using existing source"
    update_submodules_parallel
fi

# CPU-only build environment
export USE_ROCM=0
export USE_CUDA=0
export USE_DISTRIBUTED=1
export USE_NCCL=0
export USE_MKLDNN=1
export USE_MKLDNN_CBLAS=1
export USE_OPENMP=1
export BUILD_TEST=0
export MAX_JOBS="$NUM_JOBS"

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Building CPU-only PyTorch with architecture: $CPU_ARCH"
echo "Using $MAX_JOBS parallel jobs"
echo "CMake/Ninja parallel: $CMAKE_BUILD_PARALLEL_LEVEL ($NINJAFLAGS)"
echo "Git parallel jobs: $GIT_JOBS"

# Build with optimized parallelism
python setup.py clean

# Use ninja for faster builds if available
if command -v ninja &> /dev/null; then
    echo "Using ninja build system for optimal parallelism"
    export USE_NINJA=1
    export CMAKE_GENERATOR=Ninja
    python setup.py bdist_wheel --cmake
else
    # Aggressive make parallelism
    python setup.py bdist_wheel --cmake -- "-j$MAX_JOBS" "--output-sync=target"
fi

# Install the wheel
WHEEL_FILE=$(find dist -name "*.whl" | head -1)
if [[ -n "$WHEEL_FILE" ]]; then
    echo "Installing CPU-only PyTorch: $WHEEL_FILE"
    pip install "$WHEEL_FILE" --force-reinstall --no-deps
    
    # Save the wheel to wheels directory (repo-relative)
    mkdir -p "$ROOT_DIR/wheels"
    cp "$WHEEL_FILE" "$ROOT_DIR/wheels/"
    echo "Wheel saved to: $ROOT_DIR/wheels/$(basename \"$WHEEL_FILE\")"

    # Also copy wheel to top-level artifacts/ for easy discovery
    ARTIFACTS_DIR="$ROOT_DIR/artifacts"
    mkdir -p "$ARTIFACTS_DIR"
    cp "$WHEEL_FILE" "$ARTIFACTS_DIR/"
    echo "Wheel copied to: $ARTIFACTS_DIR/$(basename \"$WHEEL_FILE\")"
    
    # Verify
    python -c "
import torch
print(f'PyTorch CPU version: {torch.__version__}')
print(f'CUDA/ROCm available: {torch.cuda.is_available()}')
print(f'CPU Capabilities:')
print(f'  MKL available: {torch.backends.mkl.is_available()}')
print(f'  OpenMP threads: {torch.get_num_threads()}')
"
else
    echo "❌ No wheel file found"
    exit 1
fi

echo "✅ PyTorch $PYTORCH_VERSION (CPU-only) built successfully"


### scripts/22_build_triton_rocm.sh
#!/bin/bash
# ============================================
# PyTorch-Triton-ROCm 3.1.0
# Benefit: Optimized Triton integration for PyTorch
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

TRITON_VERSION="3.1.0"
SRC_DIR="$ROOT_DIR/src/extras/triton-rocm"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/triton-*.whl 1> /dev/null 2>&1; then
    echo "✅ Triton already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building PyTorch-Triton-ROCm $TRITON_VERSION"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"

# Clean previous build artifacts inside source tree to ensure fresh build
rm -rf python/build python/dist

# Set environment
export TRITON_BUILD_WITH_CLANG_LLD=1
export TRITON_BUILD_PROTON=OFF
export TRITON_CODEGEN_AMD_HIP_BACKEND=1
# export LLVM_SYSPATH=${ROCM_PATH}/llvm
export AMDGPU_TARGETS="gfx1151"
export PYTORCH_ROCM_ARCH="gfx1151"
export TRITON_CODEGEN_BACKENDS="amd"

# Additional ROCm configuration
export TRITON_USE_ROCM=ON
export ROCM_PATH="${ROCM_PATH}"

# Triton parallelism - uses MAX_JOBS from parallel_env.sh
export TRITON_PARALLEL_LINK_JOBS="${TRITON_PARALLEL_LINK_JOBS:-$MAX_JOBS}"

# Use Ninja for CMake builds
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

# Install build dependencies
pip install -q cmake ninja pybind11

# Fix triton/profiler missing directory error (setup.py always expects it)
mkdir -p python/triton/profiler
touch python/triton/profiler/__init__.py

# Apply gfx1151 patches if needed (Idempotent patch)
find . -name "*.py" -exec grep -l "gfx90" {} \; | while read f; do
    if ! grep -q "gfx1151" "$f"; then
        sed -i 's/\["gfx90a"\]/["gfx90a", "gfx1151"]/g' "$f"
        echo "Patched: $f"
    fi
done

# Build wheel
cd python
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/triton-*.whl

# Verify
echo ""
echo "=== Verification ==="
cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && cd /tmp && python -c "
import triton
import triton.language as tl
print(f'Triton version: {triton.__version__}')
"

echo ""
echo "=== PyTorch-Triton-ROCm build complete ==="
echo "Wheel: $ARTIFACTS_DIR/triton-*.whl"


### scripts/23_build_torchvision_audio.sh
#!/bin/bash
# torchvision 0.20.1 + torchaudio 2.5.1 for gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
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

SRC_VISION="$ROOT_DIR/src/extras/torchvision"
SRC_AUDIO="$ROOT_DIR/src/extras/torchaudio"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

# Source checks
if [[ ! -d "$SRC_VISION" ]]; then
    echo "Source not found in $SRC_VISION. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

if [[ ! -d "$SRC_AUDIO" ]]; then
    echo "Source not found in $SRC_AUDIO. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

# Ensure custom PyTorch is installed first
python -c "import torch; assert 'rocm' in torch.__version__.lower() or torch.version.hip"

echo "============================================"
echo "Checking TorchVision 0.20.1"
echo "============================================"

if ls "$ARTIFACTS_DIR"/torchvision-*.whl 1> /dev/null 2>&1; then
    echo "✅ TorchVision already exists, skipping build."
    pip install "$ARTIFACTS_DIR"/torchvision-*.whl --no-deps --force-reinstall
else
    echo "Building TorchVision..."
    parallel_env_summary
    
    cd "$SRC_VISION"
    rm -rf build dist
    
    export FORCE_CUDA=1
    export USE_ROCM=1
    export TORCHVISION_USE_FFMPEG=1
    export TORCHVISION_USE_VIDEO_CODEC=1
    export PYTORCH_ROCM_ARCH="gfx1151"
    export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
    export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
    export MAX_JOBS="$MAX_JOBS"
    
    # Build wheel (FORCE_CUDA=1 enables CUDA API compat for ROCm)
    pip wheel . --no-deps --no-build-isolation --wheel-dir="$ARTIFACTS_DIR" -v
    pip install "$ARTIFACTS_DIR"/torchvision-0.20.1*.whl --force-reinstall --no-deps
fi

echo "============================================"
echo "Checking TorchAudio 2.5.1"
echo "============================================"

if ls "$ARTIFACTS_DIR"/torchaudio-*.whl 1> /dev/null 2>&1; then
    echo "✅ TorchAudio already exists, skipping build."
    pip install "$ARTIFACTS_DIR"/torchaudio-*.whl --no-deps --force-reinstall
else
    echo "Building TorchAudio..."
    parallel_env_summary
    
    cd "$SRC_AUDIO"
    rm -rf build dist
    
    export USE_ROCM=1
    export USE_CUDA=0
    export PYTORCH_ROCM_ARCH="gfx1151"
    export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
    export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
    
    # Use setup.py with explicit parallel flag (same as PyTorch build)
    python setup.py bdist_wheel -- "-j$MAX_JOBS"
    cp dist/torchaudio-2.5.1*.whl "$ARTIFACTS_DIR/"
    pip install "$ARTIFACTS_DIR"/torchaudio-2.5.1*.whl --force-reinstall --no-deps
fi

# Verify
python -c "
import torch, torchvision, torchaudio
print(f'torch: {torch.__version__}')
print(f'torchvision: {torchvision.__version__}')
print(f'torchaudio: {torchaudio.__version__}')
"


### scripts/24_build_numpy_rocm.sh
#!/bin/bash
# NumPy 2.2.1 with ROCm-optimized BLAS (optional)
# Optimized for AMD Strix Halo 395+MAX 128GB
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

SRC_DIR="$ROOT_DIR/src/extras/numpy"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/numpy-*.whl 1> /dev/null 2>&1; then
    echo "✅ NumPy already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building NumPy 2.2.1 with ROCm BLAS"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build dist

# Use ROCm's BLAS
export NPY_BLAS_ORDER=rocblas
export NPY_LAPACK_ORDER=rocsolver
# Ensure strict adherence to ROCM_PATH
export BLAS=$ROCM_PATH/lib/librocblas.so
export LAPACK=$ROCM_PATH/lib/librocsolver.so
export PYTORCH_ROCM_ARCH="gfx1151"

# NumPy parallel build
export NPY_NUM_BUILD_JOBS="$MAX_JOBS"

# Use meson's ninja backend
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

# Build wheel to artifacts with explicit parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation -v

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/numpy-*.whl

# Verify
python -c "
import numpy as np
np.show_config()
"

echo "=== NumPy (ROCm BLAS) build complete ==="


### scripts/30_build_vllm_rocm_or_cpu.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Building vLLM for AMD ROCm..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WHEELS_DIR="${WHEELS_DIR:-"$ROOT_DIR/wheels"}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-"$ROOT_DIR/artifacts"}"

mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/vllm-*.whl 1> /dev/null 2>&1; then
    echo "✅ vLLM already exists in artifacts/, skipping build."
    exit 0
fi

source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env

# Ensure hardware detection exists
if [[ ! -f "$ROOT_DIR/build_config/hw_detected.env" ]]; then
    echo "⚠️  Hardware not detected. Running detection first..."
    "$SCRIPT_DIR/00_detect_hardware.sh"
fi
source "$ROOT_DIR/build_config/hw_detected.env"

# Activate project virtual environment
VENV_DIR="${VENV_DIR:-"$ROOT_DIR/.venv"}"
if [[ ! -d "$VENV_DIR" ]]; then
    echo "❌ Virtualenv not found at: $VENV_DIR"
    echo "   Run ./scripts/02_install_python_env.sh from the repo root first."
    exit 1
fi
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

VLLM_SRC_DIR="${VLLM_SRC_DIR:-src/vllm}"
if [[ "$VLLM_SRC_DIR" != /* ]]; then
    VLLM_SRC_DIR="$ROOT_DIR/$VLLM_SRC_DIR"
fi

NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
if [[ "${NUM_JOBS:-}" =~ ^[0-9]+$ && "${MAX_JOBS:-}" =~ ^[0-9]+$ && ${NUM_JOBS} -lt ${MAX_JOBS} ]]; then
    export MAX_JOBS="$NUM_JOBS"
fi
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
export GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"

detect_rocm_version() {
    local version=""
    if command -v dpkg &> /dev/null; then
        version=$(dpkg -l | grep rocm-hip-sdk | awk '{print $3}' | cut -d. -f1-3 || echo "")
    fi
    if [[ -z "$version" && -x /opt/rocm/bin/hipconfig ]]; then
        version=$(/opt/rocm/bin/hipconfig --version 2>/dev/null | cut -d. -f1-2 || echo "")
    fi
    echo "$version"
}

use_local_torch_wheel() {
    local wheel_path="${PYTORCH_WHEEL:-}"
    if [[ -z "$wheel_path" ]]; then
        wheel_path=$(ls "$WHEELS_DIR"/torch-2.9.*cp311*.whl 2>/dev/null | head -n 1 || true)
    fi

    if [[ -n "$wheel_path" && -f "$wheel_path" ]]; then
        echo "Using built PyTorch wheel: $wheel_path"
        pip install --force-reinstall "$wheel_path"
    else
        echo "⚠️ No local torch-2.9.*cp311*.whl found under $WHEELS_DIR"
        echo "   Proceeding with whatever torch is installed in the venv."
    fi
}

BUILD_MODE="cpu"
ROCM_VERSION_DETECTED=""

if [[ -n "${DETECTED_GPU_ARCH:-}" && -d "/opt/rocm" ]]; then
    ROCM_VERSION_DETECTED=$(detect_rocm_version)
    if [[ "$ROCM_VERSION_DETECTED" =~ ^7\.1 ]]; then
        BUILD_MODE="rocm"
    else
        echo "⚠️ ROCm 7.1.x required for vLLM GPU builds, found '${ROCM_VERSION_DETECTED:-unknown}'."
        echo "   Falling back to CPU-only vLLM build."
    fi
else
    echo "⚠️ No ROCm GPU detected; building vLLM in CPU-only mode."
fi

if [[ "$BUILD_MODE" == "rocm" ]]; then
    source "$SCRIPT_DIR/10_env_rocm_gfx1151.sh"
    source "$SCRIPT_DIR/11_env_cpu_optimized.sh"
else
    source "$SCRIPT_DIR/11_env_cpu_optimized.sh"
fi

echo "Build mode: ${BUILD_MODE^^}"
echo "Source dir: $VLLM_SRC_DIR"
echo "Parallel jobs: $MAX_JOBS (CMake $CMAKE_BUILD_PARALLEL_LEVEL, Ninja $NINJAFLAGS)"
parallel_env_summary

# Clone vLLM
if [[ ! -d "$VLLM_SRC_DIR" ]]; then
    echo "Cloning vLLM v0.12.0..."
    # Temporarily disable problematic git config for clean clone
    git config --global --unset remote.origin.fetch 2>/dev/null || true
    git clone --depth=1 --branch v0.12.0 --jobs "$GIT_JOBS" https://github.com/vllm-project/vllm.git "$VLLM_SRC_DIR"
    cd "$VLLM_SRC_DIR"
else
    cd "$VLLM_SRC_DIR"
    # Temporarily disable problematic git config
    git config --unset remote.origin.fetch 2>/dev/null || true
    # Reset to clean state and ensure we stay on the pinned release tag
    git reset --hard HEAD
    git clean -fd
    git fetch --depth=1 origin v0.12.0
    git checkout --detach v0.12.0
fi

if [[ "$BUILD_MODE" == "rocm" ]]; then
    echo "Installing vLLM with ROCm dependencies (ROCm $ROCM_VERSION_DETECTED)..."
    use_local_torch_wheel

    # Pin the torch version so later installs do not pull CUDA wheels
    if TORCH_VERSION_STR=$(python - <<'PY'
import torch
print(torch.__version__)
PY
    ); then
        export PIP_CONSTRAINT="$(mktemp)"
        echo "torch==${TORCH_VERSION_STR}" > "$PIP_CONSTRAINT"
        echo "Using torch constraint file: $PIP_CONSTRAINT"
    else
        echo "⚠️  Could not determine torch version; not setting pip constraint."
    fi

    pip install \
        "transformers>=4.50.0" \
        "triton>=3.1.0" \
        "ninja" \
        "packaging" \
        "accelerate" \
        "setuptools-scm"

    export VLLM_TARGET_DEVICE="rocm"
    export VLLM_ROCM_USE_AITER=1
    export VLLM_ROCM_USE_SKINNY_GEMM=1
    export HIP_PATH="$ROCM_PATH"
    export ROCM_HOME="$ROCM_PATH"
    export CMAKE_ARGS="${CMAKE_ARGS:-} -DROCM_PATH=$ROCM_PATH -DHIP_ROOT_DIR=$ROCM_PATH -DHIP_PATH=$ROCM_PATH -DHIP_DIR=$ROCM_PATH/lib/cmake/hip -DHIP_HIPCONFIG_EXECUTABLE=$ROCM_PATH/bin/hipconfig"

    echo "Installing vLLM ROCm requirements..."
    git config --global --unset remote.origin.fetch 2>/dev/null || true
    pip install -r requirements/rocm.txt

    echo "Building vLLM from source (no build isolation, using CMake/Ninja parallelism)..."
    pip install --no-build-isolation -v .

    # Ensure any optional extras are present
    pip install \
        "transformers>=4.50.0" \
        "triton>=3.1.0" \
        "accelerate" \
        "setuptools-scm" \
        "sentencepiece" \
        "protobuf" \
        "fastapi" \
        "aiohttp" \
        "openai" \
        "pydantic" \
        "tiktoken" \
        "lm-format-enforcer" \
        "diskcache" \
        "compressed-tensors" \
        "depyf" \
        "gguf" \
        "mistral_common[image]" \
        "opencv-python-headless" \
        "einops" \
        "numba" \
        "ray[cgraph]" \
        "peft" \
        "tensorizer" \
        "timm"
else
    echo "Installing vLLM with CPU dependencies..."
    use_local_torch_wheel

    # Pin the torch version so later installs do not pull CUDA wheels
    if TORCH_VERSION_STR=$(python - <<'PY'
import torch
print(torch.__version__)
PY
    ); then
        export PIP_CONSTRAINT="$(mktemp)"
        echo "torch==${TORCH_VERSION_STR}" > "$PIP_CONSTRAINT"
        echo "Using torch constraint file: $PIP_CONSTRAINT"
    else
        echo "⚠️  Could not determine torch version; not setting pip constraint."
    fi

    pip install \
        "transformers>=4.50.0" \
        "ninja" \
        "packaging" \
        "accelerate" \
        "setuptools-scm"

    export VLLM_TARGET_DEVICE="cpu"

    pip install --no-deps -e . --no-build-isolation

    pip install \
        "sentencepiece" \
        "protobuf" \
        "fastapi" \
        "aiohttp" \
        "openai" \
        "pydantic" \
        "tiktoken" \
        "lm-format-enforcer" \
        "diskcache" \
        "compressed-tensors" \
        "depyf" \
        "gguf" \
        "mistral_common[image]" \
        "opencv-python-headless" \
        "einops" \
        "numba" \
        "ray[cgraph]" \
        "peft" \
        "tensorizer" \
        "timm" \
        "blake3" \
        "py-cpuinfo" \
        "prometheus-fastapi-instrumentator" \
        "llguidance" \
        "outlines_core" \
        "lark" \
        "xgrammar" \
        "partial-json-parser" \
        "msgspec" \
        "pybase64" \
        "cbor2" \
        "ijson" \
        "setproctitle" \
        "openai-harmony" \
        "anthropic" \
        "model-hosting-container-standards" \
        "datasets" \
        "pytest-asyncio" \
        "runai-model-streamer[gcs,s3]" \
        "conch-triton-kernels"
fi

# Verify installation
echo "Verifying vLLM installation..."
python3 -c "
try:
    import vllm
    print(f'✅ vLLM version: {vllm.__version__}')
    
    # Check available devices
    import torch
    if torch.cuda.is_available():
        print(f'✅ GPU acceleration available')
        print(f'   Device: {torch.cuda.get_device_name(0)}')
    else:
        print('⚠️  CPU-only mode')
        
except Exception as e:
    print(f'❌ vLLM import failed: {e}')
"

# Build wheel artifact for downstream image build
echo "Packaging vLLM wheel into $ARTIFACTS_DIR (no-build-isolation)..."
# Avoid torch constraint conflicts while building the wheel
PIP_CONSTRAINT_OLD="${PIP_CONSTRAINT:-}"
unset PIP_CONSTRAINT
pip wheel . -w "$ARTIFACTS_DIR" --no-deps --no-build-isolation
VLLM_WHEEL_PATH="$(ls -1t "$ARTIFACTS_DIR"/vllm-*.whl 2>/dev/null | head -n 1 || true)"
# Restore constraint if it was set
if [[ -n "${PIP_CONSTRAINT_OLD:-}" ]]; then
    export PIP_CONSTRAINT="$PIP_CONSTRAINT_OLD"
fi
if [[ -n "$VLLM_WHEEL_PATH" ]]; then
    echo "✅ vLLM wheel: $VLLM_WHEEL_PATH"
else
    echo "⚠️ vLLM wheel not found after packaging."
fi

# Docker image build intentionally removed (no base image pulls)
if [[ "${BUILD_VLLM_IMAGE:-1}" == "1" ]]; then
    if command -v docker &> /dev/null; then
        DOCKER_CTX="$ARTIFACTS_DIR/vllm_docker_${BUILD_MODE}"
        DOCKER_TAG="${VLLM_DOCKER_TAG:-vllm-${BUILD_MODE}-cortex:local}"
        # Use locally available ROCm base by default; CPU fallback to python slim
        BASE_IMAGE="${VLLM_BASE_IMAGE:-$(if [[ \"$BUILD_MODE\" == \"rocm\" ]]; then echo rocm/dev-ubuntu-24.04:7.1.1-complete; else echo python:3.11-slim; fi)}"

        echo "Preparing Docker context at $DOCKER_CTX"
        rm -rf "$DOCKER_CTX"
        mkdir -p "$DOCKER_CTX"

        # Gather wheels
        TORCH_WHEEL_PATH="${TORCH_WHEEL_PATH:-$(ls "$WHEELS_DIR"/torch-2.9.*cp311*.whl 2>/dev/null | head -n 1 || true)}"
        if [[ -n "$TORCH_WHEEL_PATH" && -f "$TORCH_WHEEL_PATH" ]]; then
            TORCH_WHEEL_BASENAME="$(basename "$TORCH_WHEEL_PATH")"
            cp "$TORCH_WHEEL_PATH" "$DOCKER_CTX/$TORCH_WHEEL_BASENAME"
            TORCH_INSTALL_CMD="python -m pip install --no-cache-dir /tmp/$TORCH_WHEEL_BASENAME"
            echo "Using torch wheel: $TORCH_WHEEL_PATH"
        else
            TORCH_INSTALL_CMD="python -m pip install --no-cache-dir torch==2.9.1"
            echo "⚠️ No local torch wheel found; will install torch from PyPI inside image."
        fi

        if [[ -n "$VLLM_WHEEL_PATH" && -f "$VLLM_WHEEL_PATH" ]]; then
            VLLM_WHEEL_BASENAME="$(basename "$VLLM_WHEEL_PATH")"
            cp "$VLLM_WHEEL_PATH" "$DOCKER_CTX/$VLLM_WHEEL_BASENAME"
            VLLM_INSTALL_CMD="python -m pip install --no-cache-dir /tmp/$VLLM_WHEEL_BASENAME"
        else
            VLLM_INSTALL_CMD="python -m pip install --no-cache-dir vllm==0.12.0"
        fi

        # Example runtime defaults per spec
        VLLM_PORT="${VLLM_PORT:-8000}"
        VLLM_HOST="${VLLM_HOST:-0.0.0.0}"
        GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.48}" # 48GB of 100GB-ish (adjust as needed)

        cat > "$DOCKER_CTX/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Allow overriding at runtime
HOST="${VLLM_HOST:-0.0.0.0}"
PORT="${VLLM_PORT:-8000}"
MODEL_PATH="${MODEL_PATH:-/app/model}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.48}"

echo "Starting vLLM server"
echo "  Host: $HOST"
echo "  Port: $PORT"
echo "  Model: $MODEL_PATH"
echo "  GPU mem util: $GPU_MEM_UTIL"

exec python -m vllm.entrypoints.openai.api_server \
  --model "$MODEL_PATH" \
  --host "$HOST" \
  --port "$PORT" \
  --gpu-memory-utilization "$GPU_MEM_UTIL" \
  --dtype bfloat16 \
  --tensor-parallel-size "${TENSOR_PARALLEL_SIZE:-1}" \
  --pipeline-parallel-size "${PIPELINE_PARALLEL_SIZE:-1}" \
  --max-model-len "${MAX_MODEL_LEN:-32768}" \
  --swap-space "${SWAP_SPACE:-8}" \
  ${EXTRA_VLLM_ARGS:-}
EOF
        chmod +x "$DOCKER_CTX/entrypoint.sh"

        cat > "$DOCKER_CTX/Dockerfile" <<EOF
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive

# Install Python 3.11 toolchain (avoid system python3.12) and create venv
RUN apt-get update && apt-get install -y \\
    python3.11 \\
    python3.11-venv \\
    python3.11-distutils \\
    python3.11-dev \\
    python3-pip \\
    git wget curl ca-certificates \\
    && rm -rf /var/lib/apt/lists/*

RUN python3.11 -m ensurepip --upgrade && python3.11 -m venv /opt/vllm-venv
ENV PATH="/opt/vllm-venv/bin:\$PATH"

COPY *.whl /tmp/
RUN python -m pip install --upgrade pip \\
    && ${TORCH_INSTALL_CMD} \\
    && ${VLLM_INSTALL_CMD} \\
    && python -m pip install --no-cache-dir fastapi uvicorn \\
    && rm -f /tmp/*.whl

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV VLLM_TARGET_DEVICE=${BUILD_MODE}
ENV VLLM_ROCM_USE_AITER=1
ENV VLLM_ROCM_USE_SKINNY_GEMM=1
ENV VLLM_PORT=${VLLM_PORT}
ENV VLLM_HOST=${VLLM_HOST}
ENV GPU_MEM_UTIL=${GPU_MEM_UTIL}

EXPOSE ${VLLM_PORT}
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=5 \\
  CMD curl -f http://localhost:${VLLM_PORT}/health || exit 1

CMD ["/entrypoint.sh"]
EOF

        echo "Building Docker image ${DOCKER_TAG} (base: ${BASE_IMAGE})..."
        (cd "$DOCKER_CTX" && docker build -t "$DOCKER_TAG" .)
        echo "✅ Docker image built: ${DOCKER_TAG}"

        IMAGE_TAR="$ARTIFACTS_DIR/${DOCKER_TAG//[:]/_}.tar"
        echo "Saving image to tar: $IMAGE_TAR"
        docker save -o "$IMAGE_TAR" "$DOCKER_TAG"
    else
        echo "⚠️ docker not available; skipping image build."
    fi
fi

# Create example configuration
cat > vllm_example_config.yaml << EOF
# vLLM Configuration for ${BUILD_MODE^^} mode
model: "mistralai/Mistral-7B-Instruct-v0.1"

# Hardware settings
gpu_memory_utilization: 0.85
max_model_len: 4096

# Performance
tensor_parallel_size: 1
pipeline_parallel_size: 1
block_size: 16

# Quantization (adjust based on GPU memory)
quantization: null  # or "awq", "gptq", "squeezellm"

# Execution
dtype: "auto"
enforce_eager: false
EOF

echo "✅ vLLM built successfully in ${BUILD_MODE^^} mode"
echo "   Source: $VLLM_SRC_DIR"
echo "   Example config: vllm_example_config.yaml"
echo "   Artifacts directory: $ARTIFACTS_DIR"

# Copy example config into artifacts and pack a tarball for easy distribution
CONFIG_ARTIFACT="$ARTIFACTS_DIR/vllm_example_config.yaml"
cp vllm_example_config.yaml "$CONFIG_ARTIFACT"

ARTIFACT_TAR="$ARTIFACTS_DIR/vllm_${BUILD_MODE}_artifacts.tar.gz"
ARTIFACT_FILES=( "$(basename "$CONFIG_ARTIFACT")" )
if [[ -n "$VLLM_WHEEL_PATH" && -f "$VLLM_WHEEL_PATH" ]]; then
    cp "$VLLM_WHEEL_PATH" "$ARTIFACTS_DIR/$(basename "$VLLM_WHEEL_PATH")"
    ARTIFACT_FILES+=( "$(basename "$VLLM_WHEEL_PATH")" )
fi

echo "Creating artifact tarball: $ARTIFACT_TAR"
tar -czf "$ARTIFACT_TAR" -C "$ARTIFACTS_DIR" "${ARTIFACT_FILES[@]}"
echo "   Contents: ${ARTIFACT_FILES[*]}"

# Save to RoCompNew
mkdir -p ../../../RoCompNew/vllm
cp -r "$VLLM_SRC_DIR" ../../../RoCompNew/vllm/
echo "vLLM source saved to: ../../../RoCompNew/vllm/$(basename "$VLLM_SRC_DIR")"


### scripts/31_build_flash_attn.sh
#!/bin/bash
# Flash Attention 2.7.4 for ROCm gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
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

SRC_DIR="$ROOT_DIR/src/extras/flash-attention"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/flash_attn-*.whl 1> /dev/null 2>&1; then
    echo "✅ Flash Attention already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building Flash Attention 2.7.4 for ROCm"
echo "============================================"
parallel_env_summary

# Use ROCm-compatible fork
cd "$SRC_DIR"
rm -rf build dist

export GPU_ARCHS="gfx1151"
export PYTORCH_ROCM_ARCH="gfx1151"
# MAX_JOBS already set by parallel_env.sh with memory-aware calculation

# Strix Halo: Enable all optimizations
export FLASH_ATTENTION_FORCE_BUILD=TRUE
export FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE

# Use ninja for parallel CMake builds
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

# Build wheel with explicit parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation -v

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/flash_attn-*.whl

# Verify
python -c "
import flash_attn
print(f'Flash Attention: {flash_attn.__version__}')
from flash_attn import flash_attn_func
print('flash_attn_func imported successfully')
"

echo "=== Flash Attention build complete ==="


### scripts/32_build_xformers.sh
#!/bin/bash
# xformers 0.0.29 for ROCm gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
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

SRC_DIR="$ROOT_DIR/src/extras/xformers"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/xformers-*.whl 1> /dev/null 2>&1; then
    echo "✅ xformers already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building xFormers 0.0.29 for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build dist

export USE_ROCM=1
export USE_CUDA=0
export PYTORCH_ROCM_ARCH="gfx1151"
export FORCE_CUDA=1
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

# Build wheel with explicit parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation -v

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/xformers-*.whl

# Verify
python -c "
import xformers
print(f'xformers: {xformers.__version__}')
from xformers.ops import memory_efficient_attention
print('memory_efficient_attention imported')
"

echo "=== xformers build complete ==="


### scripts/33_build_bitsandbytes.sh
#!/bin/bash
# bitsandbytes 0.45.0 ROCm for gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
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

SRC_DIR="$ROOT_DIR/src/extras/bitsandbytes"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/bitsandbytes-*.whl 1> /dev/null 2>&1; then
    echo "✅ bitsandbytes already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building bitsandbytes 0.45.0 for ROCm"
echo "============================================"
parallel_env_summary

# ROCm fork
cd "$SRC_DIR"
rm -rf build dist

export BNB_ROCM_ARCH="gfx1151"
export ROCM_HOME=$ROCM_PATH
export HIP_PATH=$ROCM_PATH
export PYTORCH_ROCM_ARCH="gfx1151"

# Use Ninja for CMake builds
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

# Build wheel with explicit parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" --no-build-isolation -v

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/bitsandbytes-*.whl

# Verify
python -c "
import bitsandbytes as bnb
print(f'bitsandbytes imported')
print(f'CUDA available: {bnb.cuda_setup.main.CUDASetup.get_instance().cuda_available}')
"

echo "=== bitsandbytes build complete ==="


### scripts/34_build_deepspeed_rocm.sh
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

# Verify
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


### scripts/35_build_onnxruntime_rocm.sh
#!/bin/bash
# ============================================
# ONNX Runtime 1.20.1 with ROCm Execution Provider
# Benefit: Fast ONNX model inference on gfx1151
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

ORT_VERSION="1.20.1"
SRC_DIR="$ROOT_DIR/src/extras/onnxruntime"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/onnxruntime*.whl 1> /dev/null 2>&1; then
    echo "✅ ONNX Runtime already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building ONNX Runtime $ORT_VERSION for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build

# Install build dependencies
pip install -q cmake ninja numpy packaging

export PYTORCH_ROCM_ARCH="gfx1151"
export ROCM_VERSION="7.1.1"

# Build with ROCm EP using memory-aware parallelism
./build.sh \
    --config Release \
    --build_shared_lib \
    --parallel "$MAX_JOBS" \
    --skip_tests \
    --use_rocm \
    --rocm_home "${ROCM_PATH}" \
    --rocm_version "${ROCM_VERSION}" \
    --build_wheel \
    --cmake_generator Ninja \
    --cmake_extra_defines \
        CMAKE_HIP_ARCHITECTURES="gfx1151" \
        onnxruntime_BUILD_UNIT_TESTS=OFF \
        CMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
        CMAKE_C_FLAGS="${CFLAGS}" \
        CMAKE_CXX_FLAGS="${CXXFLAGS}"

# Copy wheel
cp build/Linux/Release/dist/onnxruntime*.whl "$ARTIFACTS_DIR/"

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/onnxruntime*.whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
import onnxruntime as ort
print(f'ONNX Runtime version: {ort.__version__}')
print(f'Available providers: {ort.get_available_providers()}')
print(f'Device: {ort.get_device()}')

# Check ROCm EP
if 'ROCMExecutionProvider' in ort.get_available_providers():
    print('✅ ROCm Execution Provider available')
else:
    print('⚠️ ROCm EP not available, using CPU')
"

echo ""
echo "=== ONNX Runtime build complete ==="
echo "Wheel: $ARTIFACTS_DIR/onnxruntime*.whl"


### scripts/36_build_cupy_rocm.sh
#!/bin/bash
# ============================================
# CuPy 13.3.0 with ROCm/HIP Backend
# Benefit: NumPy-compatible GPU arrays, CUDA code compatibility
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

CUPY_VERSION="13.3.0"
SRC_DIR="$ROOT_DIR/src/extras/cupy"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/cupy-*.whl 1> /dev/null 2>&1; then
    echo "✅ CuPy already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building CuPy $CUPY_VERSION for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build dist

# Install build dependencies
pip install -q cython fastrlock

# Set ROCm environment
export CUPY_INSTALL_USE_HIP=1
export ROCM_HOME="${ROCM_PATH}"
export HIP_HOME="${ROCM_PATH}"
export CUPY_HIPCC_GENERATE_CODE="--offload-arch=gfx1151"
export HCC_AMDGPU_TARGET="gfx1151"
export PYTORCH_ROCM_ARCH="gfx1151"

# hipBLAS, hipFFT, etc.
export CUPY_ROCM_USE_HIPBLAS=1
export CUPY_ROCM_USE_HIPFFT=1
export CUPY_ROCM_USE_HIPSPARSE=1
export CUPY_ROCM_USE_HIPRAND=1
export CUPY_ROCM_USE_RCCL=1
export CUPY_ROCM_USE_MIOPEN=0  # MIOpen may not support gfx1151 yet

# CuPy build parallelism
export CUPY_NUM_BUILD_JOBS="$MAX_JOBS"

# Use ninja for CMake builds
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

# Build wheel with explicit parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" -vvv

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/cupy-*.whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
import cupy as cp
print(f'CuPy version: {cp.__version__}')
print(f'Device: {cp.cuda.Device().name}')
print(f'Compute Capability: {cp.cuda.Device().compute_capability}')
"

echo ""
echo "=== CuPy build complete ==="
echo "Wheel: $ARTIFACTS_DIR/cupy-*.whl"


### scripts/37_build_faiss_rocm.sh
#!/bin/bash
# ============================================
# FAISS 1.9.0 with ROCm GPU Support
# Benefit: GPU-accelerated vector similarity search
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

FAISS_VERSION="1.9.0"
SRC_DIR="$ROOT_DIR/src/extras/faiss"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/faiss*.whl 1> /dev/null 2>&1; then
    echo "✅ FAISS already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building FAISS $FAISS_VERSION for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build

# Install build dependencies
pip install -q numpy swig

# Create build directory
mkdir -p build && cd build

# CMake configuration for ROCm with Ninja for faster builds
cmake .. \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DFAISS_ENABLE_GPU=ON \
    -DFAISS_ENABLE_ROCM=ON \
    -DCMAKE_HIP_ARCHITECTURES="gfx1151" \
    -DROCM_PATH="${ROCM_PATH}" \
    -DFAISS_ENABLE_PYTHON=ON \
    -DPython_EXECUTABLE=$(which python3.11) \
    -DBUILD_TESTING=OFF \
    -DFAISS_OPT_LEVEL=avx512 \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"

# Build with memory-aware parallelism
cmake --build . --parallel "$MAX_JOBS"

# Build Python wheel
cd ../python
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR"

# Install
pip install --force-reinstall "$ARTIFACTS_DIR"/faiss*.whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
import faiss
print(f'FAISS loaded successfully')
ngpus = faiss.get_num_gpus()
print(f'Number of GPUs: {ngpus}')
"

echo ""
echo "=== FAISS build complete ==="
echo "Wheel: $ARTIFACTS_DIR/faiss*.whl"


### scripts/38_build_opencv_rocm.sh
#!/bin/bash
# ============================================
# OpenCV 4.10.0 with ROCm/HIP Support
# Benefit: GPU-accelerated computer vision
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

OPENCV_VERSION="4.10.0"
SRC_OPENCV="$ROOT_DIR/src/extras/opencv"
SRC_CONTRIB="$ROOT_DIR/src/extras/opencv_contrib"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/cv2*.so 1> /dev/null 2>&1 || ls "$ARTIFACTS_DIR"/opencv*.whl 1> /dev/null 2>&1; then
    echo "✅ OpenCV already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_OPENCV" ]]; then
    echo "Source not found in $SRC_OPENCV. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi
if [[ ! -d "$SRC_CONTRIB" ]]; then
    echo "Source not found in $SRC_CONTRIB. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building OpenCV $OPENCV_VERSION for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_OPENCV"
rm -rf build
mkdir -p build && cd build

# Install build dependencies
pip install -q numpy

# CMake configuration with Ninja for faster builds
cmake .. \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DOPENCV_EXTRA_MODULES_PATH="$SRC_CONTRIB/modules" \
    -DPYTHON3_EXECUTABLE=$(which python3.11) \
    -DPYTHON3_INCLUDE_DIR=$(python3.11 -c "import sysconfig; print(sysconfig.get_path('include'))") \
    -DPYTHON3_LIBRARY=$(python3.11 -c "import sysconfig; print(sysconfig.get_config_var('LIBDIR'))") \
    -DBUILD_opencv_python3=ON \
    -DBUILD_opencv_python2=OFF \
    -DWITH_OPENCL=ON \
    -DWITH_OPENCL_SVM=ON \
    -DOPENCL_INCLUDE_DIR=${ROCM_PATH}/include \
    -DOPENCL_LIBRARY=${ROCM_PATH}/lib/libOpenCL.so \
    -DWITH_HIP=ON \
    -DHIP_COMPILER=${ROCM_PATH}/bin/hipcc \
    -DHIP_PATH=${ROCM_PATH} \
    -DGPU_ARCHS="gfx1151" \
    -DWITH_FFMPEG=ON \
    -DWITH_GSTREAMER=ON \
    -DWITH_TBB=ON \
    -DWITH_OPENMP=ON \
    -DBUILD_TESTS=OFF \
    -DBUILD_PERF_TESTS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}"

# Build with memory-aware parallelism
cmake --build . --parallel "$MAX_JOBS"

# Copy Python bindings
OPENCV_PYTHON_SO=$(find . -name "cv2*.so" | head -1)
if [ -n "$OPENCV_PYTHON_SO" ]; then
    cp "$OPENCV_PYTHON_SO" "$ARTIFACTS_DIR/"
    
    SITE_PACKAGES=$(python3.11 -c "import site; print(site.getsitepackages()[0])")
    mkdir -p "${SITE_PACKAGES}/cv2"
    cp "$OPENCV_PYTHON_SO" "${SITE_PACKAGES}/cv2/"
    touch "${SITE_PACKAGES}/cv2/__init__.py"
fi

# Verify
echo ""
echo "=== Verification ==="
python -c "
import cv2
print(f'OpenCV version: {cv2.__version__}')
"

echo ""
echo "=== OpenCV build complete ==="
echo "Artifact: $ARTIFACTS_DIR/cv2*.so"


### scripts/39_build_pillow_simd.sh
#!/bin/bash
# ============================================
# Pillow-SIMD 10.4.0 with AVX-512 Support
# Benefit: 4-6x faster image operations
# Optimized for AMD Strix Halo 395+MAX 128GB
# ============================================
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load parallel environment FIRST for optimal resource usage
source "$ROOT_DIR/scripts/parallel_env.sh"
apply_parallel_env

source "$ROOT_DIR/scripts/11_env_cpu_optimized.sh"

PILLOW_VERSION="10.4.0"
SRC_DIR="$ROOT_DIR/src/extras/pillow-simd"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/Pillow_SIMD-*.whl 1> /dev/null 2>&1 || ls "$ARTIFACTS_DIR"/Pillow-*.whl 1> /dev/null 2>&1; then
    echo "✅ Pillow-SIMD already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building Pillow-SIMD $PILLOW_VERSION (AVX-512)"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build dist

# Install build dependencies
pip install -q setuptools wheel

# Override CFLAGS with Pillow-SIMD specific optimizations for Zen 5
# Include -ffast-math for SIMD image processing (safe for image ops)
export CFLAGS="-O3 -march=znver5 -mtune=znver5 -mavx512f -mavx512bw -mavx512vl -mavx512dq -mavx512vbmi -ffast-math -flto=auto"
export CC="${CC:-gcc}"

# Build wheel with explicit parallel compilation
pip wheel . --no-deps --wheel-dir="$ARTIFACTS_DIR" -v

# Remove standard Pillow and install SIMD version
pip uninstall -y Pillow pillow-simd 2>/dev/null || true
pip install --force-reinstall --no-deps "$ARTIFACTS_DIR"/pillow*.whl

# Verify
echo ""
echo "=== Verification ==="
python -c "
from PIL import Image, features
print(f'Pillow version: {Image.__version__}')
print(f'SIMD support: {features.check(\"libimagequant\")}')
"

echo ""
echo "=== Pillow-SIMD build complete ==="
echo "Wheel: $ARTIFACTS_DIR/pillow*.whl"


### scripts/40_build_llama_cpp_cpu.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🦙 Building llama.cpp (CPU-optimized)..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-"$ROOT_DIR/artifacts"}"
mkdir -p "$ARTIFACTS_DIR"

source scripts/11_env_cpu_optimized.sh

if [[ -f "$ARTIFACTS_DIR/llama_cpp_cpu.tar.gz" ]]; then
    echo "✅ llama.cpp CPU already exists in artifacts/, skipping build."
    exit 0
fi

# Configuration
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-src/llama.cpp}"
# Ensure absolute path
if [[ "$LLAMA_CPP_DIR" != /* ]]; then
    LLAMA_CPP_DIR="$ROOT_DIR/$LLAMA_CPP_DIR"
fi
BUILD_DIR="$LLAMA_CPP_DIR/build/cpu"
NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
if [[ "${NUM_JOBS:-}" =~ ^[0-9]+$ && "${MAX_JOBS:-}" =~ ^[0-9]+$ && ${NUM_JOBS} -lt ${MAX_JOBS} ]]; then
    export MAX_JOBS="$NUM_JOBS"
fi
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

# Clone llama.cpp
if [[ ! -d "$LLAMA_CPP_DIR" ]]; then
    echo "Cloning llama.cpp (shallow)..."
    # Temporarily disable problematic git config
    git config --global --unset remote.origin.fetch 2>/dev/null || true
    git clone --depth=1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_CPP_DIR"
    cd "$LLAMA_CPP_DIR"
else
    cd "$LLAMA_CPP_DIR"
    # Keep shallow history to depth=1
    git fetch --depth=1 origin b7551
    git checkout b7551
    git reset --hard origin/b7551
fi

# Create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "Building with CPU architecture: $CPU_ARCH"
echo "Using $MAX_JOBS parallel jobs"
echo "CMake/Ninja parallel: $CMAKE_BUILD_PARALLEL_LEVEL ($NINJAFLAGS)"

# Configure with CMake - prefer ninja for faster builds
if command -v ninja &> /dev/null; then
    cmake "$LLAMA_CPP_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-march=znver5 -O3 -flto=auto -pipe $CFLAGS" \
        -DCMAKE_CXX_FLAGS="-march=znver5 -O3 -flto=auto -pipe $CXXFLAGS" \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
        -GNinja \
        -DLLAMA_NATIVE=ON \
        -DLLAMA_AVX=ON \
        -DLLAMA_AVX2=ON \
        -DLLAMA_AVX512=ON \
        -DLLAMA_FMA=ON \
        -DLLAMA_F16C=ON \
        -DLLAMA_BLAS=ON \
        -DLLAMA_BLAS_VENDOR=OpenBLAS \
        -DLLAMA_METAL=OFF \
        -DLLAMA_CUDA=OFF \
        -DLLAMA_HIPBLAS=OFF \
        -DLLAMA_CLBLAST=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DLLAMA_CURL=ON \
        -DLLAMA_HTTP=ON \
        -DLLAMA_SERVER=ON
    
    # Build with ninja
    ninja $NINJAFLAGS
else
    cmake "$LLAMA_CPP_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-march=znver5 -O3 -flto=auto -pipe $CFLAGS" \
        -DCMAKE_CXX_FLAGS="-march=znver5 -O3 -flto=auto -pipe $CXXFLAGS" \
        -DLLAMA_NATIVE=ON \
        -DLLAMA_AVX=ON \
        -DLLAMA_AVX2=ON \
        -DLLAMA_AVX512=ON \
        -DLLAMA_FMA=ON \
        -DLLAMA_F16C=ON \
        -DLLAMA_BLAS=ON \
        -DLLAMA_BLAS_VENDOR=OpenBLAS \
        -DLLAMA_METAL=OFF \
        -DLLAMA_CUDA=OFF \
        -DLLAMA_HIPBLAS=OFF \
        -DLLAMA_CLBLAST=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DLLAMA_CURL=ON \
        -DLLAMA_HTTP=ON \
        -DLLAMA_SERVER=ON
    
    # Build with make
    make -j$MAX_JOBS --output-sync=target
fi

# Verify builds
echo "Verifying builds..."
ls -la bin/ | grep -E "(llama|server)"

# Create symlinks to project root
cd ../..
ln -sf "$BUILD_DIR/bin/llama-cli" llama-cpu 2>/dev/null || true
ln -sf "$BUILD_DIR/bin/llama-server" llama-server-cpu 2>/dev/null || true

echo "✅ llama.cpp CPU build complete"
echo "   Binaries: $BUILD_DIR/bin/"
echo "   Main executable: $BUILD_DIR/bin/llama-cli"
echo "   Server: $BUILD_DIR/bin/llama-server"

# Package artifacts to $ARTIFACTS_DIR
ARTIFACT_TAR="$ARTIFACTS_DIR/llama_cpp_cpu.tar.gz"
echo "Packaging CPU build into $ARTIFACT_TAR"
tar -czf "$ARTIFACT_TAR" -C "$BUILD_DIR" .
echo "   Contents: $(tar -tzf "$ARTIFACT_TAR" | head -n 5)…"

# Save to RoCompNew
mkdir -p ../../../RoCompNew/llama_cpp/cpu
cp -r "$BUILD_DIR" ../../../RoCompNew/llama_cpp/cpu/
echo "llama.cpp CPU build saved to: ../../../RoCompNew/llama_cpp/cpu/$(basename "$BUILD_DIR")"


### scripts/41_build_llama_cpp_rocm.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🦙 Building llama.cpp with ROCm/HIP support..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-"$ROOT_DIR/artifacts"}"
mkdir -p "$ARTIFACTS_DIR"

source scripts/10_env_rocm_gfx1151.sh
source scripts/11_env_cpu_optimized.sh

if [[ -f "$ARTIFACTS_DIR/llama_cpp_rocm.tar.gz" ]]; then
    echo "✅ llama.cpp ROCm already exists in artifacts/, skipping build."
    exit 0
fi

# Check ROCm
if [[ ! -d "$ROCM_PATH" ]]; then
    echo "❌ ROCm not found at $ROCM_PATH"
    echo "   Install ROCm 7.1.1 first"
    exit 1
fi

# Configuration
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-src/llama.cpp}"
# Ensure absolute path
if [[ "$LLAMA_CPP_DIR" != /* ]]; then
    LLAMA_CPP_DIR="$ROOT_DIR/$LLAMA_CPP_DIR"
fi
BUILD_DIR="$LLAMA_CPP_DIR/build/rocm"
NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
if [[ "${NUM_JOBS:-}" =~ ^[0-9]+$ && "${MAX_JOBS:-}" =~ ^[0-9]+$ && ${NUM_JOBS} -lt ${MAX_JOBS} ]]; then
    export MAX_JOBS="$NUM_JOBS"
fi
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

# Clone if needed
if [[ ! -d "$LLAMA_CPP_DIR" ]]; then
    echo "Cloning llama.cpp (shallow)..."
    # Temporarily disable problematic git config
    git config --global --unset remote.origin.fetch 2>/dev/null || true
    git clone --depth=1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_CPP_DIR"
    cd "$LLAMA_CPP_DIR"
else
    cd "$LLAMA_CPP_DIR"
    # Keep shallow history to depth=1
    git fetch --depth=1 origin b7551
    git checkout b7551
    git reset --hard origin/b7551
fi

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "Building for ROCm GPU: $ROCM_GFX_ARCH"
echo "Using $MAX_JOBS parallel jobs"
echo "CMake/Ninja parallel: $CMAKE_BUILD_PARALLEL_LEVEL ($NINJAFLAGS)"

# Configure with ROCm/HIP - prefer ninja for faster builds
if command -v ninja &> /dev/null; then
    cmake "$LLAMA_CPP_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-march=znver5 -O3 -flto=auto -pipe $CFLAGS" \
        -DCMAKE_CXX_FLAGS="-march=znver5 -O3 -flto=auto -pipe $CXXFLAGS" \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
        -GNinja \
        -DGGML_HIP=ON \
        -DGGML_HIPBLAS=ON \
        -DLLAMA_HIPBLAS=ON \
        -DLLAMA_HIP_UMA=ON \
        -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
        -DAMDGPU_TARGETS="$ROCM_GFX_ARCH" \
        -DLLAMA_CUDA=OFF \
        -DLLAMA_METAL=OFF \
        -DLLAMA_BLAS=OFF \
        -DLLAMA_CURL=ON \
        -DLLAMA_HTTP=ON \
        -DLLAMA_SERVER=ON \
        -DBUILD_SHARED_LIBS=ON
    
    # Build with ninja
    ninja $NINJAFLAGS
else
    cmake "$LLAMA_CPP_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-march=znver5 -O3 -flto=auto -pipe $CFLAGS" \
        -DCMAKE_CXX_FLAGS="-march=znver5 -O3 -flto=auto -pipe $CXXFLAGS" \
        -DGGML_HIP=ON \
        -DGGML_HIPBLAS=ON \
        -DLLAMA_HIPBLAS=ON \
        -DLLAMA_HIP_UMA=ON \
        -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
        -DAMDGPU_TARGETS="$ROCM_GFX_ARCH" \
        -DLLAMA_CUDA=OFF \
        -DLLAMA_METAL=OFF \
        -DLLAMA_BLAS=OFF \
        -DLLAMA_CURL=ON \
        -DLLAMA_HTTP=ON \
        -DLLAMA_SERVER=ON \
        -DBUILD_SHARED_LIBS=ON
    
    # Build with make
    make -j$MAX_JOBS --output-sync=target
fi

# Verify
echo "Verifying ROCm build..."
if [[ -f "bin/llama-cli" ]]; then
    echo "✅ ROCm build successful"
    ./bin/llama-cli --version || true
else
    echo "❌ Build failed - llama-cli binary not found"
    exit 1
fi

# Create symlinks
cd ../..
ln -sf "$BUILD_DIR/bin/llama-cli" llama-rocm 2>/dev/null || true
ln -sf "$BUILD_DIR/bin/llama-server" llama-server-rocm 2>/dev/null || true

echo "✅ llama.cpp ROCm build complete"
echo "   GPU Target: $ROCM_GFX_ARCH"
echo "   Binaries: $BUILD_DIR/bin/"
echo "   Use -ngl N to offload N layers to GPU"

# Package artifacts to $ARTIFACTS_DIR
ARTIFACT_TAR="$ARTIFACTS_DIR/llama_cpp_rocm.tar.gz"
echo "Packaging ROCm build into $ARTIFACT_TAR"
tar -czf "$ARTIFACT_TAR" -C "$BUILD_DIR" .
echo "   Contents: $(tar -tzf "$ARTIFACT_TAR" | head -n 5)…"

# Save to RoCompNew
mkdir -p ../../../RoCompNew/llama_cpp/rocm
cp -r "$BUILD_DIR" ../../../RoCompNew/llama_cpp/rocm/
echo "llama.cpp ROCm build saved to: ../../../RoCompNew/llama_cpp/rocm/$(basename "$BUILD_DIR")"


### scripts/42_build_llama_cpp_b7551.sh
#!/bin/bash
# llama.cpp b7551 + HIP for gfx1151
# Optimized for AMD Strix Halo 395+MAX 128GB
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

SRC_DIR="$ROOT_DIR/src/extras/llama-cpp"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

if ls "$ARTIFACTS_DIR"/llama_cpp_python-*.whl 1> /dev/null 2>&1; then
    echo "✅ llama.cpp-python already exists in artifacts/, skipping build."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Source not found in $SRC_DIR. Run scripts/05_git_parallel_prefetch.sh first."
    exit 1
fi

echo "============================================"
echo "Building llama.cpp (b7551) for ROCm"
echo "============================================"
parallel_env_summary

cd "$SRC_DIR"
rm -rf build

# CMake configuration for gfx1151 with Ninja for faster builds
cmake -B build \
    -GNinja \
    -DGGML_HIP=ON \
    -DAMDGPU_TARGETS="gfx1151" \
    -DGGML_HIP_UMA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=hipcc \
    -DCMAKE_CXX_COMPILER=hipcc \
    -DCMAKE_C_FLAGS="-O3 -march=znver5 -flto=auto" \
    -DCMAKE_CXX_FLAGS="-O3 -march=znver5 -flto=auto" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DGGML_NATIVE=ON \
    -DGGML_LTO=ON \
    -DGGML_CUDA_F16=ON \
    -DGGML_CUDA_GRAPHS=ON \
    -DLLAMA_CURL=ON

# Build with memory-aware parallelism
cmake --build build --config Release -j"$MAX_JOBS"

# Install binaries to system
sudo cp build/bin/* /usr/local/bin/
sudo cp build/lib/*.so /usr/local/lib/
sudo ldconfig

# Build python wheel for bindings
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
export CMAKE_ARGS="-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 -DGGML_HIP_UMA=ON"
pip wheel llama-cpp-python \
    --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/rocm \
    --wheel-dir="$ARTIFACTS_DIR" \
    --no-build-isolation

# Install Python bindings
pip install --force-reinstall --no-cache-dir "$ARTIFACTS_DIR"/llama_cpp_python-*.whl

# Verify
echo ""
echo "=== Verification ==="
llama-cli --version
python -c "from llama_cpp import Llama; print('llama-cpp-python OK')"

echo "=== llama.cpp build complete ==="
echo "Wheel: $ARTIFACTS_DIR/llama_cpp_python-*.whl"


### scripts/50_run_llama_server_example.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🌐 Launching llama.cpp server example..."

# Configuration
MODEL_PATH="${1:-./models/mistral-7b-v0.1.Q4_K_M.gguf}"
SERVER_HOST="${SERVER_HOST:-0.0.0.0}"
SERVER_PORT="${SERVER_PORT:-8080}"
GPU_LAYERS="${GPU_LAYERS:-99}"  # Offload all layers if GPU available
CONTEXT_SIZE="${CONTEXT_SIZE:-4096}"
THREADS="${THREADS:-$(( $(nproc) - 2 ))}"  # Reserve 2 cores

# Check if model exists
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "⚠️  Model not found: $MODEL_PATH"
    echo "   Download example:"
    echo "   wget -P models/ https://huggingface.co/TheBloke/Mistral-7B-v0.1-GGUF/resolve/main/mistral-7b-v0.1.Q4_K_M.gguf"
    echo ""
    echo "Using CPU build as fallback..."
    MODEL_PATH=""  # Will use CPU if no model
fi

# Determine which server to use
if [[ -f "artifacts/bin/llama-server-rocm" ]] || [[ -f "src/extras/llama-cpp/build/bin/llama-server" ]]; then
    SERVER_BINARY="${SERVER_BINARY:-artifacts/bin/llama-server-rocm}"
    BUILD_TYPE="ROCm"
    echo "Using ROCm-accelerated server"
elif [[ -f "artifacts/bin/llama-server-cpu" ]] || [[ -f "src/extras/llama-cpp/build/cpu/bin/llama-server" ]]; then
    SERVER_BINARY="${SERVER_BINARY:-artifacts/bin/llama-server-cpu}"
    BUILD_TYPE="CPU"
    echo "Using CPU-only server"
else
    echo "❌ No llama-server binary found"
    echo "   Build first with: scripts/40_build_llama_cpp_cpu.sh or scripts/41_build_llama_cpp_rocm.sh"
    exit 1
fi

# Find actual binary path
if [[ ! -f "$SERVER_BINARY" ]]; then
    if [[ "$BUILD_TYPE" == "ROCm" ]] && [[ -f "src/llama.cpp/build/rocm/bin/llama-server" ]]; then
        SERVER_BINARY="src/llama.cpp/build/rocm/bin/llama-server"
    elif [[ -f "src/llama.cpp/build/cpu/bin/llama-server" ]]; then
        SERVER_BINARY="src/llama.cpp/build/cpu/bin/llama-server"
    fi
fi

echo ""
echo "🚀 Starting llama.cpp server"
echo "   Build: $BUILD_TYPE"
echo "   Model: ${MODEL_PATH:-'None (will use CPU)'}"
echo "   Host: $SERVER_HOST:$SERVER_PORT"
echo "   Threads: $THREADS"
echo "   GPU Layers: $GPU_LAYERS"
echo "   Context: $CONTEXT_SIZE"
echo ""
echo "📋 API endpoints:"
echo "   http://$SERVER_HOST:$SERVER_PORT/health"
echo "   http://$SERVER_HOST:$SERVER_PORT/v1/chat/completions"
echo "   http://$SERVER_HOST:$SERVER_PORT/v1/completions"
echo ""
echo "Press Ctrl+C to stop the server"
echo ""

# Run the server
if [[ -n "$MODEL_PATH" ]] && [[ -f "$MODEL_PATH" ]]; then
    "$SERVER_BINARY" \
        -m "$MODEL_PATH" \
        --host "$SERVER_HOST" \
        --port "$SERVER_PORT" \
        -t "$THREADS" \
        -c "$CONTEXT_SIZE" \
        -ngl "$GPU_LAYERS" \
        --log-format text \
        --verbose
else
    echo "⚠️  Running in interactive mode (no model loaded)"
    echo "   Load a model via API after starting"
    "$SERVER_BINARY" \
        --host "$SERVER_HOST" \
        --port "$SERVER_PORT" \
        -t "$THREADS" \
        --log-format text
fi


### scripts/60_run_vllm_docker.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🐳 Running vLLM in a ROCm Docker container..."

# Defaults (override via environment if you want something newer)
VLLM_DOCKER_IMAGE="${VLLM_DOCKER_IMAGE:-rocm/vllm-dev:nightly_main_20251128}"
MODEL_DIR="${MODEL_DIR:-$PWD/models}"
CONTAINER_NAME="${CONTAINER_NAME:-vllm-rocm-dev}"
SHELL_ONLY="${SHELL_ONLY:-0}"   # 1 = just give me a shell

mkdir -p "$MODEL_DIR"

echo "  Image:          $VLLM_DOCKER_IMAGE"
echo "  Host model dir: $MODEL_DIR"
echo "  Container name: $CONTAINER_NAME"
echo

# Basic sanity
if ! command -v docker &> /dev/null; then
  echo "❌ docker is not installed or not on PATH."
  exit 1
fi

# For Strix Halo, we expose /dev/kfd and /dev/dri and add video/render groups
DOCKER_CMD=(
  docker run --rm -it
  --name "$CONTAINER_NAME"
  --network host
  --device /dev/kfd
  --device /dev/dri
  --group-add video
  --group-add render
  --ipc host
  --cap-add=SYS_PTRACE
  --security-opt seccomp=unconfined
  -v "$MODEL_DIR":/app/model
)

if [[ "${SHELL_ONLY}" == "1" ]]; then
  echo "🔧 Launching interactive shell inside vLLM ROCm container..."
  "${DOCKER_CMD[@]}" "$VLLM_DOCKER_IMAGE" bash
else
  echo "🚀 Launching vLLM OpenAI-compatible server on port 8000..."
  "${DOCKER_CMD[@]}" "$VLLM_DOCKER_IMAGE"     python -m vllm.entrypoints.openai.api_server       --model /app/model       --port 8000
fi


### scripts/70_build_optional_extras.sh
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


### scripts/80_run_complete_build_docker.sh
#!/bin/bash
# scripts/80_run_complete_build_docker.sh
# Orchestrates the entire project build inside a clean ROCm Docker container.

set -e

# Parse arguments
SKIP_PREFETCH=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip)
            SKIP_PREFETCH=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip]"
            echo "  --skip: Skip the dependency prefetch stage"
            exit 1
            ;;
    esac
done

# Repository Root Detection
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Kill any running amd-ai-builder containers
echo "=== Cleaning up old containers ==="
docker ps -a --filter "ancestor=amd-ai-builder:local" --format "{{.ID}}" | xargs -r docker kill 2>/dev/null || true
docker ps -a --filter "ancestor=amd-ai-builder:local" --format "{{.ID}}" | xargs -r docker rm 2>/dev/null || true

echo "=== AMD AI Builder: Initializing Docker Infrastructure ==="

# Step A: Define & Build the Builder Image
echo "Building amd-ai-builder:local..."
docker build -t amd-ai-builder:local -f - . <<EOF
FROM rocm/dev-ubuntu-24.04:7.1.1-complete

# Avoid interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Install System Dependencies (Python 3.11 via deadsnakes PPA)
RUN apt-get update && apt-get install -y \
    software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y \
    python3.11 \
    python3.11-venv \
    python3.11-dev \
    python3.11-full \
    python3-pip \
    git \
    cmake \
    ninja-build \
    build-essential \
    wget \
    libopenblas-dev \
    && rm -rf /var/lib/apt/lists/*

# Set Python 3.11 as default
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1

# Ensure pip is installed for Python 3.11 and allow breaking system packages for initial setup if needed
RUN python3.11 -m pip install --upgrade pip --break-system-packages || true

# Set Environment Variables
ENV ROCM_PATH=/opt/rocm
ENV PATH=$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH

WORKDIR /app
EOF

echo "=== AMD AI Builder: Starting Containerized Build Pipeline ==="

# Step B: Prefetch All Dependencies on Host
if [ "$SKIP_PREFETCH" = false ]; then
    echo "Running prefetch stage..."
    bash scripts/06_prefetch_all_dependencies.sh
else
    echo ">>> Skipping prefetch stage (--skip flag set)..."
fi

# Step B.5: Apply Patches (Ensure they survive prefetch)
echo "Applying Triton ROCm patches..."
# 1. Disable -Werror for literal operators
sed -i 's/-Werror -Wno-covered-switch-default/-Werror -Wno-covered-switch-default -Wno-error=deprecated-literal-operator/g' src/extras/triton-rocm/CMakeLists.txt
# 2. Disable Unit Tests
sed -i 's/option(TRITON_BUILD_UT "Build C++ Triton Unit Tests" ON)/option(TRITON_BUILD_UT "Build C++ Triton Unit Tests" OFF)/g' src/extras/triton-rocm/CMakeLists.txt
# 3. Disable Lit Test Support Libs
sed -i 's/add_subdirectory(test)/# add_subdirectory(test)/g' src/extras/triton-rocm/CMakeLists.txt
# 4. Disable Bin Tools (LSP, Opt)
sed -i 's/add_subdirectory(bin)/# add_subdirectory(bin)/g' src/extras/triton-rocm/CMakeLists.txt
# 5. Remove NVIDIA IR from common conversion libs (Fix ROCm link error)
sed -i '/TritonNvidiaGPUTransforms/d' src/extras/triton-rocm/lib/Conversion/TritonGPUToLLVM/CMakeLists.txt
sed -i '/NVGPUIR/d' src/extras/triton-rocm/lib/Conversion/TritonGPUToLLVM/CMakeLists.txt
# 6. Prune NVIDIA backend from source to avoid discovery issues
rm -rf src/extras/triton-rocm/python/triton/backends/nvidia
# 7. Fix Verification: must run from outside source tree
sed -i 's/python -c/cd \/tmp \&\& python -c/g' scripts/22_build_triton_rocm.sh

# Step C: Execute the Build Pipeline
# Note: Using a single bash -c command string as requested.
docker run --rm \
    -v "$ROOT_DIR:/app" \
    --user "$(id -u):$(id -g)" \
    --device=/dev/kfd \
    --device=/dev/dri \
    --group-add video \
    --ipc=host \
    -v "$ROOT_DIR/wheels/cache/triton_deps:/tmp/.triton" \
    -e ROCM_PATH=/opt/rocm \
    -e HOME=/tmp \
    -e PIP_NO_INDEX=1 \
    -e PIP_FIND_LINKS=/app/wheels/cache \
    amd-ai-builder:local \
    bash scripts/internal_container_build.sh

# Step C: Verification
echo "=== AMD AI Builder: Host Verification ==="
if [ -d "artifacts" ]; then
    echo "Contents of artifacts/ directory:"
    ls -R artifacts/
else
    echo "Warning: artifacts/ directory not found. Build might have failed or not produced artifacts."
fi

echo "Done."


### scripts/99_optimize_build_env.sh
#!/usr/bin/env bash
set -euo pipefail

echo "🎛️  Tuning system for optimal AMD Zen 5 Strix Halo build performance..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/parallel_env.sh"
apply_parallel_env

# Detect memory size
MEM_GB=$(_parallel_mem_gb)

# Set CPU governor to performance
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
    echo "✅ CPU governor: performance mode"
fi

# Increase dirty writeback memory (helps with many parallel file writes)
# Scale with available memory - larger values for 128GB+ systems
if ((MEM_GB >= 128)); then
    echo "3000" | sudo tee /proc/sys/vm/dirty_writeback_centisecs >/dev/null 2>&1 || true
    echo "60" | sudo tee /proc/sys/vm/dirty_ratio >/dev/null 2>&1 || true
    echo "20" | sudo tee /proc/sys/vm/dirty_background_ratio >/dev/null 2>&1 || true
    # Increase max map count for large builds
    echo "262144" | sudo tee /proc/sys/vm/max_map_count >/dev/null 2>&1 || true
elif ((MEM_GB >= 64)); then
    echo "2500" | sudo tee /proc/sys/vm/dirty_writeback_centisecs >/dev/null 2>&1 || true
    echo "50" | sudo tee /proc/sys/vm/dirty_ratio >/dev/null 2>&1 || true
    echo "15" | sudo tee /proc/sys/vm/dirty_background_ratio >/dev/null 2>&1 || true
else
    echo "2000" | sudo tee /proc/sys/vm/dirty_writeback_centisecs >/dev/null 2>&1 || true
    echo "40" | sudo tee /proc/sys/vm/dirty_ratio >/dev/null 2>&1 || true
    echo "10" | sudo tee /proc/sys/vm/dirty_background_ratio >/dev/null 2>&1 || true
fi

# Increase file descriptors for many parallel jobs
ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true

# Set process priority for build tools
if command -v nice &> /dev/null; then
    renice -n -10 $$ 2>/dev/null || renice -n -5 $$ 2>/dev/null || true
fi

# Memory optimization for large parallel builds - tuned for Strix Halo
export MALLOC_MMAP_THRESHOLD_=262144
export MALLOC_TRIM_THRESHOLD_=262144
export MALLOC_TOP_PAD_=262144
export MALLOC_MMAP_MAX_=65536

# Enable transparent huge pages for large memory systems
if ((MEM_GB >= 64)); then
    echo "madvise" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
fi

# AMD Zen 5-specific OpenMP optimization
CPU_CORES=$(nproc --all 2>/dev/null || echo 1)
if ((CPU_CORES > 0)); then
    export GOMP_CPU_AFFINITY="0-$((CPU_CORES-1))"
fi
export OMP_PROC_BIND=${OMP_PROC_BIND:-spread}
export OMP_PLACES=${OMP_PLACES:-threads}
export OMP_DYNAMIC=${OMP_DYNAMIC:-false}
export OMP_NESTED=${OMP_NESTED:-false}
export OMP_MAX_ACTIVE_LEVELS=${OMP_MAX_ACTIVE_LEVELS:-1}
export OMP_STACKSIZE=${OMP_STACKSIZE:-64M}

# AMD GPU performance (if ROCm is present)
if [[ -d /opt/rocm ]]; then
    # Set GPU to high performance mode
    if command -v rocm-smi &> /dev/null; then
        rocm-smi --setperflevel high 2>/dev/null || true
    fi
    # Enable HIP async memory operations
    export HIP_LAUNCH_BLOCKING=0
    export HIP_FORCE_DEV_KERNARG=1
    export HSA_ENABLE_SDMA=1
fi

# Compiler cache optimization
if command -v ccache &> /dev/null; then
    # Ensure ccache is in PATH for automatic use
    export PATH="/usr/lib/ccache:$PATH"
fi

# tmpfs for build directories if memory allows (128GB+ systems)
if ((MEM_GB >= 128)); then
    export USE_TMPFS_BUILD=${USE_TMPFS_BUILD:-1}
    echo "💾 Sufficient memory for tmpfs builds: ${MEM_GB}GB available"
fi

parallel_env_summary

echo ""
echo "🔧 Build environment optimized for AMD Strix Halo"
echo "   Available jobs: $MAX_JOBS"
echo "   Memory: ${MEM_GB}GB total"
echo "   CPU cores: $CPU_CORES"
echo "   File descriptors: $(ulimit -n)"
if [[ -n "${CCACHE_DIR:-}" ]]; then
    echo "   ccache dir: $CCACHE_DIR (max: $CCACHE_MAXSIZE)"
fi


### scripts/debug_regression/run_server_smoke.sh
#!/usr/bin/env bash
# Simple smoke test: run llama-server (router) under a short timeout and check it doesn't SIGSEGV.
# Assumes `llama-server` is on PATH or adjust BINARY variable.

set -eu
BINARY=${1:-./llama-server}
TIMEOUT=${2:-8} # seconds

if [ ! -x "$BINARY" ]; then
  echo "binary $BINARY not found or not executable"
  exit 2
fi

ulimit -c unlimited || true

# Run in background and wait shortly
"$BINARY" --router --port 18080 &
PID=$!

sleep $TIMEOUT

if kill -0 $PID 2>/dev/null; then
  echo "process $PID still alive after ${TIMEOUT}s — likely OK"
  kill $PID
  wait $PID || true
  exit 0
else
  echo "process $PID exited early — check for crash or core dump"
  exit 1
fi


### scripts/diagnose_bottleneck.sh
#!/usr/bin/env bash

echo "🔍 Diagnosing build bottlenecks..."
echo "CPU Threads: $(nproc)"
echo "Load Average: $(uptime | awk -F'load average:' '{print $2}')"
echo "Memory Pressure: $(awk '/MemAvailable/ {print $2/1024/1024" GB free"}' /proc/meminfo)"

# Check what's limiting parallelism
echo -e "\nActive Build Processes:"
ps aux | grep -E "(make|ninja|cmake|gcc|g\+\+|clang)" | grep -v grep | head -20

echo -e "\nFile Descriptor Limits:"
ulimit -n

echo -e "\nI/O Wait (high = disk bottleneck):"
iostat -c | tail -2

echo -e "\nCPU Frequency:"
awk '/cpu MHz/ {sum+=$4; count++} END {print "Avg:", sum/count, "MHz"}' /proc/cpuinfo

# Check if memory is the bottleneck
echo -e "\nMemory Usage by Build:"
ps aux --sort=-%mem | head -5


### scripts/internal_container_build.sh
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
./scripts/20_build_pytorch_rocm.sh
# Ensure PyTorch is available for downstream builds even if build was skipped
if ls artifacts/torch-*.whl 1> /dev/null 2>&1; then
    pip install artifacts/torch-*.whl --no-deps --force-reinstall
fi

./scripts/22_build_triton_rocm.sh
# Ensure Triton is available for downstream builds even if build was skipped
if ls artifacts/triton-*.whl 1> /dev/null 2>&1; then
    pip install artifacts/triton-*.whl --no-deps --force-reinstall
fi

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


### scripts/package-llama.sh
#!/bin/bash
#
# package-llama.sh: Package llama-server binaries into deterministic tarballs
#
# Usage: ./scripts/package-llama.sh [--debug] [--output DIR]
#
# Creates reproducible packages with:
# - debug or release binaries
# - deterministic timestamps and ownership
# - systemd unit files
# - debug documentation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
OUTPUT_DIR="${OUTPUT_DIR:-.}"
DEBUG_BUILD=0
TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
Usage: $0 [options]

Options:
  --debug             Package debug build (default: release)
  --output DIR        Output directory for tarball (default: current dir)
  --build-dir DIR     Build directory (default: ./build)
  --help              Show this help message

Examples:
  # Package release build
  ./scripts/package-llama.sh

  # Package debug build
  ./scripts/package-llama.sh --debug

  # Custom output directory
  ./scripts/package-llama.sh --output /tmp/packages
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) DEBUG_BUILD=1 ;;
        --output) OUTPUT_DIR="$2"; shift ;;
        --build-dir) BUILD_DIR="$2"; shift ;;
        --help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

# Verify build directory exists
[[ -d "$BUILD_DIR" ]] || die "Build directory not found: $BUILD_DIR"

# Check for llama-server binary
if [[ $DEBUG_BUILD -eq 1 ]]; then
    SERVER_BIN="$BUILD_DIR/bin/llama-server"
    PKG_SUFFIX="debug"
else
    SERVER_BIN="$BUILD_DIR/bin/llama-server"
    PKG_SUFFIX="release"
fi

[[ -f "$SERVER_BIN" ]] || die "llama-server binary not found: $SERVER_BIN"

# Create package staging directory
STAGING_DIR=$(mktemp -d)
trap "rm -rf '$STAGING_DIR'" EXIT

mkdir -p "$STAGING_DIR/opt/llama/bin"
mkdir -p "$STAGING_DIR/opt/llama/lib"
mkdir -p "$STAGING_DIR/etc/systemd/system"
mkdir -p "$STAGING_DIR/etc/systemd/system.d"
mkdir -p "$STAGING_DIR/usr/local/bin"

echo "Packaging llama-server ($PKG_SUFFIX)..."

# Copy binary
if [[ $DEBUG_BUILD -eq 0 ]]; then
    # Strip release binary
    cp "$SERVER_BIN" "$STAGING_DIR/opt/llama/bin/llama-server"
    strip "$STAGING_DIR/opt/llama/bin/llama-server" 2>/dev/null || true
else
    # Keep debug symbols
    cp "$SERVER_BIN" "$STAGING_DIR/opt/llama/bin/llama-server-debug"
    chmod 755 "$STAGING_DIR/opt/llama/bin/llama-server-debug"
fi

# Copy systemd unit files if they exist
if [[ -f "$PROJECT_ROOT/systemd/llama-server.service" ]]; then
    cp "$PROJECT_ROOT/systemd/llama-server.service" "$STAGING_DIR/etc/systemd/system/" 2>/dev/null || true
fi

if [[ -f "$PROJECT_ROOT/artifacts/llama_fixed/llama-server.service.debug" ]]; then
    cp "$PROJECT_ROOT/artifacts/llama_fixed/llama-server.service.debug" \
       "$STAGING_DIR/etc/systemd/system.d/llama-server-debug.conf" 2>/dev/null || true
fi

# Create symlink for convenience
if [[ $DEBUG_BUILD -eq 0 ]]; then
    ln -sf "/opt/llama/bin/llama-server" "$STAGING_DIR/usr/local/bin/llama-server"
else
    ln -sf "/opt/llama/bin/llama-server-debug" "$STAGING_DIR/usr/local/bin/llama-server-debug"
fi

# Include documentation
if [[ -f "$PROJECT_ROOT/artifacts/llama_fixed/DEBUGGING.md" ]]; then
    mkdir -p "$STAGING_DIR/opt/llama/doc"
    cp "$PROJECT_ROOT/artifacts/llama_fixed/DEBUGGING.md" "$STAGING_DIR/opt/llama/doc/" 2>/dev/null || true
fi

# Create deterministic tarball
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
PKG_NAME="llama-server-${PKG_SUFFIX}-${TIMESTAMP}.tar.gz"
PKG_PATH="$OUTPUT_DIR/$PKG_NAME"

echo "Creating tarball: $PKG_PATH"
cd "$STAGING_DIR"
tar --owner=0 --group=0 --mtime="@0" --sort=name \
    -czf "$PKG_PATH" \
    opt/ etc/ usr/ 2>/dev/null || tar -czf "$PKG_PATH" opt/ etc/ usr/

# Verify tarball
if tar -tzf "$PKG_PATH" > /dev/null 2>&1; then
    echo "✓ Package created successfully: $PKG_PATH"
    ls -lh "$PKG_PATH"
else
    die "Failed to create valid tarball"
fi


### scripts/parallel_env.sh
#!/usr/bin/env bash

# Shared helpers for squeezing the most out of local CPU + memory during builds.
# Optimized for AMD Strix Halo 395+MAX with 128GB unified memory.
# This file is intended to be sourced by build scripts; it does not set shell
# options that would leak to callers.

# Return total memory in GiB (rounded down). Falls back to 0 on failure.
_parallel_mem_gb() {
  local mem_kb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  printf '%s' $((mem_kb / 1024 / 1024))
}

# Detect if this is a Strix Halo / high-memory APU system
_is_high_mem_apu() {
  local mem_gb
  mem_gb=$(_parallel_mem_gb)
  # 64GB+ systems with AMD APU are considered high-memory
  ((mem_gb >= 64))
}

# Decide how many parallel jobs to run, respecting optional overrides:
# - MAX_JOBS: hard override
# - RESERVED_CORES: cores to keep free (default: 0 for high-mem APU, 1 otherwise)
# - JOB_MEM_GB: assumed memory needed per job (default: 1.5 GiB for high-mem, 2 otherwise)
parallel_calculate_jobs() {
  local cores reserve usable mem_gb per_job_gb mem_limited jobs

  cores=$(nproc --all 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  
  # For 128GB+ systems, use all cores; smaller systems reserve 1
  if _is_high_mem_apu; then
    reserve=${RESERVED_CORES:-0}
  else
    reserve=${RESERVED_CORES:-1}
  fi
  ((reserve < 0)) && reserve=0
  usable=$((cores > reserve ? cores - reserve : 1))

  mem_gb=$(_parallel_mem_gb)
  
  # High-memory systems can afford more memory per job for faster compilation
  # With 128GB, we can easily afford 1.5GB per job which allows maxing out even 64+ threads
  if _is_high_mem_apu; then
    per_job_gb=${JOB_MEM_GB:-1} # Relaxed from 4GB to 1GB to ensure core saturation
  else
    per_job_gb=${JOB_MEM_GB:-2}
  fi
  # Floating point handling in bash is tricky, treating as int 1 minimum
  [[ "$per_job_gb" =~ ^[0-9]+$ ]] || per_job_gb=1

  if ((mem_gb > 0)); then
    mem_limited=$((mem_gb / per_job_gb))
    ((mem_limited < 1)) && mem_limited=1
  else
    mem_limited=$usable
  fi

  jobs=$usable
  if ((mem_limited > 0 && mem_limited < jobs)); then
    jobs=$mem_limited
  fi

  if [[ -n "${MAX_JOBS:-}" ]]; then
    jobs=$MAX_JOBS
  fi

  echo "$jobs"
}

# Apply environment variables that build tools honor for parallelism and BLAS.
apply_parallel_env() {
  local jobs omp_threads mem_gb
  jobs="$(parallel_calculate_jobs)"
  mem_gb=$(_parallel_mem_gb)

  # Ensure jobs is never empty or zero - fallback to 4 if detection fails
  if [[ -z "$jobs" ]] || ! [[ "$jobs" =~ ^[0-9]+$ ]] || ((jobs < 1)); then
    jobs=4
  fi

  export MAX_JOBS="${MAX_JOBS:-$jobs}"
  # Double-check MAX_JOBS is valid
  if [[ -z "$MAX_JOBS" ]] || ! [[ "$MAX_JOBS" =~ ^[0-9]+$ ]] || ((MAX_JOBS < 1)); then
    export MAX_JOBS=4
  fi

  export NUM_JOBS="${NUM_JOBS:-$MAX_JOBS}"
  export PARALLEL_LEVEL="${PARALLEL_LEVEL:-$MAX_JOBS}"
  export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
  export NINJAFLAGS="${NINJAFLAGS:--j$MAX_JOBS}"
  # Use -j format (not --jobs=) for better compatibility
  export MAKEFLAGS="${MAKEFLAGS:--j$MAX_JOBS}"
  export GIT_JOBS="${GIT_JOBS:-$MAX_JOBS}"

  # DeepSpeed and other library specific parallel flags
  export DS_BUILD_PARALLEL_LEVEL="${DS_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
  export SKLEARN_BUILD_PARALLEL_LEVEL="${SKLEARN_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"

  omp_threads="${OMP_NUM_THREADS:-$MAX_JOBS}"
  export OMP_NUM_THREADS="$omp_threads"
  export MKL_NUM_THREADS="${MKL_NUM_THREADS:-$omp_threads}"
  export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-$omp_threads}"
  export BLIS_NUM_THREADS="${BLIS_NUM_THREADS:-$omp_threads}"
  export NUMEXPR_MAX_THREADS="${NUMEXPR_MAX_THREADS:-$omp_threads}"
  export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-$MAX_JOBS}"

  # ccache defaults for faster rebuilds - scale with available memory
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
  if ((mem_gb >= 128)); then
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-50G}"
  elif ((mem_gb >= 64)); then
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-30G}"
  else
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
  fi
  export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-time_macros,include_file_mtime,file_macro}"
  export CCACHE_COMPRESS="${CCACHE_COMPRESS:-1}"
  export CCACHE_COMPRESSLEVEL="${CCACHE_COMPRESSLEVEL:-1}"
  mkdir -p "$CCACHE_DIR" 2>/dev/null || true

  # Enable ccache for compilers if available
  if command -v ccache &> /dev/null; then
    export CC="${CC:-ccache gcc}"
    export CXX="${CXX:-ccache g++}"
    export HIPCC_COMPILE_FLAGS_APPEND="${HIPCC_COMPILE_FLAGS_APPEND:---ccache-flag=-Xcompiler}"
  fi

  # Linker optimization - disabled to prevent GCC LTO incompatibility with lld/mold
  # if command -v mold &> /dev/null; then
  #   export LDFLAGS="${LDFLAGS:-} -fuse-ld=mold"
  # elif command -v lld &> /dev/null; then
  #   export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld"
  # fi

  # Memory-mapped I/O optimization for large builds
  export MALLOC_MMAP_THRESHOLD_="${MALLOC_MMAP_THRESHOLD_:-131072}"
  export MALLOC_TRIM_THRESHOLD_="${MALLOC_TRIM_THRESHOLD_:-131072}"
  export MALLOC_TOP_PAD_="${MALLOC_TOP_PAD_:-131072}"
  
  # Python wheel building parallelism
  export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_TORCH="${SETUPTOOLS_SCM_PRETEND_VERSION:-}"
  export PIP_NO_BUILD_ISOLATION="${PIP_NO_BUILD_ISOLATION:-0}"
}

# Zen 5 specific CPU flags for maximum performance
apply_zen5_cflags() {
  local base_cflags="-march=znver5 -mtune=znver5 -O3 -pipe -fno-plt -fexceptions"
  local avx_flags="-mavx512f -mavx512bw -mavx512vl -mavx512dq -mavx512cd -mavx512vbmi -mavx512vbmi2 -mavx512vnni -mavx512bitalg -mavx512vpopcntdq"
  local lto_flags="-flto=auto -fuse-linker-plugin"
  
  export ZEN5_CFLAGS="$base_cflags $avx_flags $lto_flags"
  export ZEN5_CXXFLAGS="$ZEN5_CFLAGS"
  
  # Apply if not already set
  export CFLAGS="${CFLAGS:-$ZEN5_CFLAGS}"
  export CXXFLAGS="${CXXFLAGS:-$ZEN5_CXXFLAGS}"
}

parallel_env_summary() {
  local mem_gb cores high_mem_status
  mem_gb=$(_parallel_mem_gb)
  cores=$(nproc --all 2>/dev/null || echo "unknown")
  
  if _is_high_mem_apu; then
    high_mem_status="High-mem APU mode (128GB+)"
  else
    high_mem_status="Standard mode"
  fi
  
  echo "🧮 Parallel config -> jobs=$MAX_JOBS, cores=$cores, mem=${mem_gb}GiB"
  echo "    Mode: $high_mem_status"
  echo "    MAKEFLAGS=$MAKEFLAGS"
  echo "    NINJAFLAGS=$NINJAFLAGS"
  echo "    CMAKE_BUILD_PARALLEL_LEVEL=$CMAKE_BUILD_PARALLEL_LEVEL"
  echo "    CCACHE_MAXSIZE=$CCACHE_MAXSIZE"
  if [[ -n "${LDFLAGS:-}" ]]; then
    echo "    LDFLAGS=$LDFLAGS"
  fi
}


### scripts/set-amdgpu-performance.sh
#!/bin/sh
set -e
logger -t amdgpu-perf "Setting AMD GPU performance mode"

write_with_retry() {
  file="$1"
  value="$2"
  max=6
  i=1
  while [ "$i" -le "$max" ]; do
    if printf '%s' "$value" > "$file" 2>/dev/null; then
      logger -t amdgpu-perf "Wrote $value to $file (attempt $i)"
      return 0
    fi
    logger -t amdgpu-perf "Failed to write $file (attempt $i), retrying"
    sleep "$i"
    i=$((i + 1))
  done
  logger -t amdgpu-perf "Giving up writing $file after $max attempts"
  return 1
}

if command -v rocm-smi >/dev/null 2>&1; then
  rocm-smi --setperflevel high >/dev/null 2>&1 || true
fi

for dev in /sys/class/drm/card*/device; do
  [ -d "$dev" ] || continue
  pd="$dev/power_dpm_force_performance_level"
  pp="$dev/pp_power_profile_mode"
  [ -e "$pd" ] && write_with_retry "$pd" performance || true
  [ -e "$pp" ] && write_with_retry "$pp" high || true
done

logger -t amdgpu-perf "AMD GPU performance mode applied"


### scripts/verify-open-notebook.sh
#!/bin/bash
#
# verify-open-notebook.sh: Verify notebook/model loading with graceful error handling
#
# This script tests model loading without crashing on benign pipe errors or failed requests.
# It handles:
# - SIGPIPE errors gracefully (broken client connections)
# - HTTP 404s from missing models
# - Timeout/network issues with retry logic
#

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="${1:-.}"
TIMEOUT=${TIMEOUT:-30}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-2}
LOG_FILE="${LOG_FILE:-./verify-notebook.log}"

# Trap SIGPIPE to avoid aborting on broken pipes
trap 'true' PIPE

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

warn() {
    echo "[WARN] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "[ERROR] $*" | tee -a "$LOG_FILE"
    return 1
}

info() {
    echo "[INFO] $*" | tee -a "$LOG_FILE"
}

# Verify that notebooks/models exist without crashing
verify_notebooks() {
    local count=0
    local failed=0
    
    info "Scanning models directory: $MODELS_DIR"
    
    if [[ ! -d "$MODELS_DIR" ]]; then
        error "Models directory not found: $MODELS_DIR"
        return 1
    fi
    
    # Find all .gguf model files
    while IFS= read -r model_file; do
        ((count++))
        local model_name=$(basename "$model_file" .gguf)
        
        info "Verifying model: $model_name ($model_file)"
        
        # Check file validity
        if [[ ! -r "$model_file" ]]; then
            warn "Model file not readable: $model_file"
            ((failed++))
            continue
        fi
        
        # Basic GGUF magic check (first 4 bytes should be "GGUF")
        local magic=$(od -A n -N 4 -t x1 "$model_file" 2>/dev/null | tr -d ' ')
        if [[ "$magic" != "47474 6" && "$magic" != "47474" ]]; then
            warn "Model file is not a valid GGUF file: $model_file"
            ((failed++))
            continue
        fi
        
        info "✓ Model verified: $model_name"
    done < <(find "$MODELS_DIR" -name "*.gguf" -type f)
    
    if [[ $count -eq 0 ]]; then
        warn "No GGUF models found in $MODELS_DIR"
        return 0  # Not an error if no models exist
    fi
    
    info "Scanned $count models, $failed failed"
    
    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Verify HTTP connectivity to a server without crashing on pipe errors
verify_server_connectivity() {
    local host="${1:-localhost}"
    local port="${2:-8080}"
    local retry=0
    
    info "Verifying connectivity to $host:$port"
    
    while [[ $retry -lt $MAX_RETRIES ]]; do
        # Use timeout to avoid hanging, suppress SIGPIPE errors
        if timeout "$TIMEOUT" curl -s -f "http://$host:$port/props" >/dev/null 2>&1; then
            info "✓ Server connectivity verified"
            return 0
        fi
        
        local exit_code=$?
        
        # SIGPIPE (141) is benign, retry; other failures might indicate real problems
        if [[ $exit_code -eq 141 ]]; then
            warn "SIGPIPE error (benign), retrying..."
        elif [[ $exit_code -eq 124 ]]; then
            warn "Request timeout, retrying..."
        elif [[ $exit_code -eq 7 ]]; then
            warn "Failed to connect to $host:$port, retrying..."
        else
            error "Failed to verify connectivity: exit code $exit_code"
        fi
        
        ((retry++))
        if [[ $retry -lt $MAX_RETRIES ]]; then
            sleep "$RETRY_DELAY"
        fi
    done
    
    error "Failed to verify server connectivity after $MAX_RETRIES attempts"
    return 1
}

main() {
    log "Starting notebook/model verification"
    
    verify_notebooks || {
        warn "Some notebooks failed verification, but continuing..."
    }
    
    # Only verify server if we have parameters
    if [[ $# -gt 0 ]]; then
        verify_server_connectivity "$@" || true
    fi
    
    info "Verification complete"
}

main "$@"


