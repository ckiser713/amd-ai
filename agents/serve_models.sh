#!/usr/bin/env bash
set -euo pipefail

# Serve both DeepSeek models for agentic workflow
echo "Starting DeepSeek model servers for agentic troubleshooting..."

# Configuration
MODELS_DIR="${MODELS_DIR:-./models}"
VLLM_PORT_PLANNER=8001
VLLM_PORT_EXECUTOR=8002
TOKENIZER="deepseek-ai/deepseek-llm-67b-chat"  # Using base tokenizer

# Download models if needed
mkdir -p "$MODELS_DIR"
cd "$MODELS_DIR"

# Planner: DeepSeek-V3.2-Speciale (Reasoning-focused)
if [[ ! -d "DeepSeek-V3.2-Speciale" ]]; then
    echo "Downloading DeepSeek-V3.2-Speciale for planning..."
    # Using HuggingFace download (adjust based on availability)
    huggingface-cli download deepseek-ai/DeepSeek-V3.2-Speciale \
        --local-dir DeepSeek-V3.2-Speciale \
        --local-dir-use-symlinks False \
        --exclude "*.safetensors" \
        --max-files 10
fi

# Executor: DeepSeek-V3.2 (Tool-enabled)
if [[ ! -d "DeepSeek-V3.2" ]]; then
    echo "Downloading DeepSeek-V3.2 for execution..."
    huggingface-cli download deepseek-ai/DeepSeek-V3.2 \
        --local-dir DeepSeek-V3.2 \
        --local-dir-use-symlinks False \
        --exclude "*.safetensors" \
        --max-files 10
fi

cd ..

# Start Planner Server (Speciale - API only)
echo "Starting Planner server (port $VLLM_PORT_PLANNER)..."
vllm serve "$MODELS_DIR/DeepSeek-V3.2-Speciale" \
    --port $VLLM_PORT_PLANNER \
    --tokenizer-mode deepseek_v32 \
    --max-model-len 131072 \
    --gpu-memory-utilization 0.7 \
    --enforce-eager \
    --compilation-config 3 \
    --disable-log-requests \
    --host 0.0.0.0 &

PLANNER_PID=$!

# Start Executor Server (Standard V3.2 - with tool support)
echo "Starting Executor server (port $VLLM_PORT_EXECUTOR)..."
vllm serve "$MODELS_DIR/DeepSeek-V3.2" \
    --port $VLLM_PORT_EXECUTOR \
    --tokenizer-mode deepseek_v32 \
    --tool-call-parser deepseek_v32 \
    --max-model-len 131072 \
    --gpu-memory-utilization 0.8 \
    --enforce-eager \
    --compilation-config 3 \
    --host 0.0.0.0 &

EXECUTOR_PID=$!

# Save PIDs for cleanup
echo $PLANNER_PID > .planner_pid
echo $EXECUTOR_PID > .executor_pid

echo "✅ Agents serving on:"
echo "   Planner (Speciale): http://localhost:$VLLM_PORT_PLANNER"
echo "   Executor (V3.2):    http://localhost:$VLLM_PORT_EXECUTOR"
echo ""
echo "To stop: ./agents/stop_agents.sh"
