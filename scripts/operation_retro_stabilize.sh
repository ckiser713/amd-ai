#!/bin/bash
set -euo pipefail

echo "🚀 Starting Operation Retro-Stabilize (Option 1) - Strix Halo"
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Phase 1: Demolition & Unlock
echo "💥 Phase 1: Demolition & Unlock"

echo "   Removing artifacts..."
rm -f "$APP_ROOT"/artifacts/torch-*.whl
rm -f "$APP_ROOT"/artifacts/triton-*.whl
rm -f "$APP_ROOT"/artifacts/xformers-*.whl
rm -f "$APP_ROOT"/artifacts/flash_attn-*.whl
echo "   Artifacts purged."

echo "   Unlocking build scripts..."
if [[ -f "$APP_ROOT/scripts/lock_manager.sh" ]]; then
    "$APP_ROOT/scripts/lock_manager.sh" --unlock \
        scripts/20_build_pytorch_rocm.sh \
        scripts/22_build_triton_rocm.sh \
        scripts/32_build_xformers.sh
else
    echo "⚠️ scripts/lock_manager.sh not found, checking for manual locks..."
    rm -f "$APP_ROOT/scripts/20_build_pytorch_rocm.sh.lock"
    rm -f "$APP_ROOT/scripts/22_build_triton_rocm.sh.lock"
    rm -f "$APP_ROOT/scripts/32_build_xformers.sh.lock"
fi
echo "   Scripts unlocked."

# Phase 4: Execution
echo "🏁 Phase 4: Execution"
echo "   Starting silent build runner..."
"$APP_ROOT/scripts/silent_build_runner.sh"
