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
