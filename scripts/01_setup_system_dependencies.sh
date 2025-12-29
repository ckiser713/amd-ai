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
