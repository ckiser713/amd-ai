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
