#!/usr/bin/env bash
source .venv/bin/activate
echo "Python virtual environment activated"
echo "Python: $(python --version)"
echo "Pip: $(pip --version | cut -d' ' -f2)"
