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
