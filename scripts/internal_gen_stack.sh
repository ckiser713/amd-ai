#!/usr/bin/env bash
# scripts/internal_gen_stack.sh
# Generates the installer script for the final artifacts
set -e

ARTIFACTS_DIR="${1:-artifacts}"
mkdir -p "$ARTIFACTS_DIR"

INSTALLER_PATH="$ARTIFACTS_DIR/install-gfx1151-stack.sh"

echo ">>> Generating $INSTALLER_PATH..."
cat > "$INSTALLER_PATH" << 'EOF'
#!/usr/bin/env bash
set -e
echo "Installing Zenith MPG-1 Stack (gfx1151)..."
# Force reinstall of wheels in the current directory
# This script is intended to be distributed with the wheels
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pip install --force-reinstall --no-deps "$DIR"/*.whl
echo "Done. Stack installed."
EOF

chmod +x "$INSTALLER_PATH"
echo "Generated $INSTALLER_PATH"
