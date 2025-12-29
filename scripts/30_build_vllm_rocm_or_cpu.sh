#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Building vLLM for AMD ROCm..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WHEELS_DIR="${WHEELS_DIR:-"$ROOT_DIR/wheels"}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-"$ROOT_DIR/artifacts"}"

mkdir -p "$ARTIFACTS_DIR"

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
