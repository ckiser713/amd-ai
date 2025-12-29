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
