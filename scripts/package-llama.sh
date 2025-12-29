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
