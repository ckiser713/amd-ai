#!/usr/bin/env bash
# Simple launcher for AMD build troubleshooter
set -euo pipefail

echo "🛠️  AMD Build Troubleshooter (DeepSeek API)"
echo "=========================================="

# Check for API key
if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
    echo "❌ ERROR: DEEPSEEK_API_KEY environment variable not set"
    echo ""
    echo "Setup instructions:"
    echo "1. Get API key from: https://platform.deepseek.com/"
    echo "2. Set it temporarily:"
    echo "   export DEEPSEEK_API_KEY='your-key-here'"
    echo "3. Or set it permanently in ~/.bashrc:"
    echo "   echo \"export DEEPSEEK_API_KEY='your-key-here'\" >> ~/.bashrc"
    echo "   source ~/.bashrc"
    exit 1
fi

# Check Python dependencies
if ! python3 -c "import requests" 2>/dev/null; then
    echo "Installing Python dependencies..."
    pip install requests
fi

# Run the troubleshooter
python3 agents/api_troubleshooter.py "$@"
