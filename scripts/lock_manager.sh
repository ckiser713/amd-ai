#!/usr/bin/env bash
# ============================================================================
# Lock Manager — Shell Script Governance Utility
# ============================================================================
# Prevents regressions by locking successful build scripts and tracking
# dependencies in a matrix.
#
# Usage:
#   ./scripts/lock_manager.sh --lock <script_path>
#   ./scripts/lock_manager.sh --unlock <script_path>
#   ./scripts/lock_manager.sh --check <script_path>
#   ./scripts/lock_manager.sh --scan-artifacts
#   ./scripts/lock_manager.sh --update-matrix
#
# Sourceable functions:
#   source scripts/lock_manager.sh
#   check_lock "$0" || exit 1
#   lock_script "$0"
# ============================================================================
set -euo pipefail

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUPS_DIR="$ROOT_DIR/backups/locks"
MATRIX_FILE="$ROOT_DIR/build_config/dependency_matrix.json"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"

# Ensure directories exist
mkdir -p "$BACKUPS_DIR"
mkdir -p "$(dirname "$MATRIX_FILE")"

# ============================================================================
# ARTIFACT-TO-SCRIPT MAPPING
# ============================================================================
# Maps artifact patterns to their build scripts
declare -A ARTIFACT_SCRIPT_MAP=(
    ["torch-"]="scripts/20_build_pytorch_rocm.sh"
    ["numpy-"]="scripts/24_build_numpy_rocm.sh"
    ["triton-"]="scripts/22_build_triton_rocm.sh"
    ["torchvision-"]="scripts/23_build_torchvision_audio.sh"
    ["torchaudio-"]="scripts/23_build_torchvision_audio.sh"
    ["flash_attn-"]="scripts/31_build_flash_attn.sh"
    ["xformers-"]="scripts/32_build_xformers.sh"
    ["bitsandbytes-"]="scripts/33_build_bitsandbytes.sh"
    ["deepspeed-"]="scripts/34_build_deepspeed_rocm.sh"
    ["onnxruntime-"]="scripts/35_build_onnxruntime_rocm.sh"
    ["cupy-"]="scripts/36_build_cupy_rocm.sh"
    ["faiss-"]="scripts/37_build_faiss_rocm.sh"
    ["opencv-"]="scripts/38_build_opencv_rocm.sh"
    ["pillow-"]="scripts/39_build_pillow_simd.sh"
    ["vllm-"]="scripts/30_build_vllm_rocm_or_cpu.sh"
)

# ============================================================================
# DEPENDENCY MAP
# ============================================================================
# Defines upstream dependencies for each script
declare -A UPSTREAM_DEPS=(
    ["scripts/20_build_pytorch_rocm.sh"]="scripts/24_build_numpy_rocm.sh"
    ["scripts/22_build_triton_rocm.sh"]="scripts/20_build_pytorch_rocm.sh"
    ["scripts/23_build_torchvision_audio.sh"]="scripts/20_build_pytorch_rocm.sh"
    ["scripts/30_build_vllm_rocm_or_cpu.sh"]="scripts/20_build_pytorch_rocm.sh scripts/22_build_triton_rocm.sh"
    ["scripts/31_build_flash_attn.sh"]="scripts/20_build_pytorch_rocm.sh"
    ["scripts/32_build_xformers.sh"]="scripts/20_build_pytorch_rocm.sh"
    ["scripts/33_build_bitsandbytes.sh"]="scripts/20_build_pytorch_rocm.sh"
    ["scripts/34_build_deepspeed_rocm.sh"]="scripts/20_build_pytorch_rocm.sh"
    ["scripts/35_build_onnxruntime_rocm.sh"]="scripts/20_build_pytorch_rocm.sh"
    ["scripts/36_build_cupy_rocm.sh"]="scripts/20_build_pytorch_rocm.sh"
    ["scripts/37_build_faiss_rocm.sh"]="scripts/20_build_pytorch_rocm.sh"
    ["scripts/38_build_opencv_rocm.sh"]=""
    ["scripts/39_build_pillow_simd.sh"]=""
)

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

get_lock_file() {
    local script_path="$1"
    echo "${script_path}.lock"
}

get_script_version() {
    local script_path="$1"
    if [[ -f "$ROOT_DIR/$script_path" ]]; then
        # Use git hash if available, otherwise md5sum
        if git -C "$ROOT_DIR" rev-parse --git-dir &>/dev/null; then
            git -C "$ROOT_DIR" log -1 --format="%h" -- "$script_path" 2>/dev/null || echo "untracked"
        else
            md5sum "$ROOT_DIR/$script_path" 2>/dev/null | cut -d' ' -f1 | head -c 8
        fi
    else
        echo "unknown"
    fi
}

# ============================================================================
# LOCK FUNCTION
# ============================================================================
# Creates a lock file and backup for a script
do_lock() {
    local script_path="$1"
    local artifact="${2:-}"
    local full_path="$ROOT_DIR/$script_path"
    local lock_file
    lock_file=$(get_lock_file "$full_path")
    
    # Verify script exists
    if [[ ! -f "$full_path" ]]; then
        echo "❌ Script not found: $script_path"
        return 1
    fi
    
    # Check if already locked
    if [[ -f "$lock_file" ]]; then
        echo "⚠️  Script already locked: $script_path"
        cat "$lock_file"
        return 0
    fi
    
    local timestamp
    timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    local version
    version=$(get_script_version "$script_path")
    local script_name
    script_name=$(basename "$script_path" .sh)
    
    # Create backup directory
    local backup_dir="$BACKUPS_DIR/${script_name}_${timestamp}_${version}"
    mkdir -p "$backup_dir"
    cp "$full_path" "$backup_dir/"
    
    # Create lock file
    cat > "$lock_file" << EOF
{
    "locked_at": "$timestamp",
    "version": "$version",
    "script": "$script_path",
    "artifact": "$artifact",
    "backup": "$backup_dir",
    "locked_by": "lock_manager"
}
EOF
    
    # Remove write permissions (optional, can be enabled)
    # chmod -w "$full_path"
    
    echo "🔒 Locked: $script_path"
    echo "   Version: $version"
    echo "   Backup: $backup_dir"
    [[ -n "$artifact" ]] && echo "   Artifact: $artifact"
    
    # Update matrix
    update_matrix_entry "$script_path" "LOCKED" "$artifact"
    
    return 0
}

# ============================================================================
# UNLOCK FUNCTION
# ============================================================================
do_unlock() {
    local script_path="$1"
    local full_path="$ROOT_DIR/$script_path"
    local lock_file
    lock_file=$(get_lock_file "$full_path")
    
    if [[ ! -f "$lock_file" ]]; then
        echo "✅ Script is not locked: $script_path"
        return 0
    fi
    
    # Restore write permissions if removed
    chmod +w "$full_path" 2>/dev/null || true
    
    # Remove lock file
    rm -f "$lock_file"
    
    echo "🔓 Unlocked: $script_path"
    
    # Update matrix
    update_matrix_entry "$script_path" "UNLOCKED" ""
    
    return 0
}

# ============================================================================
# CHECK FUNCTION
# ============================================================================
# Returns 0 if unlocked, 1 if locked
do_check() {
    local script_path="$1"
    local full_path="$ROOT_DIR/$script_path"
    local lock_file
    lock_file=$(get_lock_file "$full_path")
    
    if [[ -f "$lock_file" ]]; then
        echo "🔒 LOCKED: $script_path"
        echo "--- Lock Details ---"
        cat "$lock_file"
        return 1
    else
        echo "✅ UNLOCKED: $script_path"
        return 0
    fi
}

# ============================================================================
# SOURCEABLE FUNCTIONS (for use in build scripts)
# ============================================================================

# Check if script is locked - returns 0 if UNLOCKED, 1 if LOCKED
check_lock() {
    if [[ "${IGNORE_LOCKS:-0}" == "1" ]]; then
        return 0  # Bypass lock check
    fi
    local script_path="$1"
    # Handle both absolute and relative paths
    if [[ "$script_path" == /* ]]; then
        script_path="${script_path#$ROOT_DIR/}"
    fi
    
    local full_path="$ROOT_DIR/$script_path"
    local lock_file
    lock_file=$(get_lock_file "$full_path")
    
    if [[ -f "$lock_file" ]]; then
        return 1  # Locked
    fi
    return 0  # Unlocked
}

# Lock a script after successful build
lock_script() {
    local script_path="$1"
    local artifact="${2:-}"
    
    # Handle both absolute and relative paths
    if [[ "$script_path" == /* ]]; then
        script_path="${script_path#$ROOT_DIR/}"
    fi
    
    do_lock "$script_path" "$artifact"
}

# ============================================================================
# SCAN ARTIFACTS FUNCTION
# ============================================================================
do_scan_artifacts() {
    echo "🔍 Scanning artifacts directory for build outputs..."
    
    if [[ ! -d "$ARTIFACTS_DIR" ]]; then
        echo "⚠️  No artifacts directory found"
        return 0
    fi
    
    local locked_count=0
    
    for artifact in "$ARTIFACTS_DIR"/*.whl "$ARTIFACTS_DIR"/*; do
        [[ -f "$artifact" ]] || continue
        local artifact_name
        artifact_name=$(basename "$artifact")
        
        for pattern in "${!ARTIFACT_SCRIPT_MAP[@]}"; do
            if [[ "$artifact_name" == ${pattern}* ]]; then
                local script="${ARTIFACT_SCRIPT_MAP[$pattern]}"
                local full_script_path="$ROOT_DIR/$script"
                local lock_file
                lock_file=$(get_lock_file "$full_script_path")
                
                if [[ -f "$full_script_path" && ! -f "$lock_file" ]]; then
                    echo "📦 Found: $artifact_name → $script"
                    do_lock "$script" "$artifact_name"
                    locked_count=$((locked_count + 1))
                fi
                break
            fi
        done
    done
    
    echo ""
    echo "✅ Scan complete. Locked $locked_count script(s)."
    
    # Regenerate matrix after scan
    do_update_matrix
}

# ============================================================================
# UPDATE MATRIX FUNCTIONS
# ============================================================================

update_matrix_entry() {
    local script_path="$1"
    local status="$2"
    local artifact="${3:-}"
    
    # Initialize matrix if doesn't exist
    if [[ ! -f "$MATRIX_FILE" ]]; then
        echo "{}" > "$MATRIX_FILE"
    fi
    
    local timestamp
    timestamp=$(date +%Y-%m-%d)
    local upstream="${UPSTREAM_DEPS[$script_path]:-}"
    
    # Use jq if available, otherwise use sed/awk
    if command -v jq &>/dev/null; then
        local tmp_file
        tmp_file=$(mktemp)
        
        jq --arg script "$script_path" \
           --arg status "$status" \
           --arg date "$timestamp" \
           --arg artifact "$artifact" \
           --arg upstream "$upstream" \
           '.[$script] = {
               "status": $status,
               "last_success": $date,
               "artifact": $artifact,
               "upstream_deps": ($upstream | split(" ") | map(select(. != ""))),
               "downstream_dependents": []
           }' "$MATRIX_FILE" > "$tmp_file"
        
        mv "$tmp_file" "$MATRIX_FILE"
    else
        echo "⚠️  jq not found, matrix update skipped"
    fi
}

do_update_matrix() {
    echo "📊 Regenerating dependency matrix..."
    
    # Start fresh matrix
    echo "{}" > "$MATRIX_FILE"
    
    # Scan all build scripts
    for script in "$ROOT_DIR"/scripts/[0-9][0-9]_build_*.sh; do
        [[ -f "$script" ]] || continue
        local script_rel="${script#$ROOT_DIR/}"
        local lock_file
        lock_file=$(get_lock_file "$script")
        
        local status="UNLOCKED"
        local artifact=""
        local last_date
        last_date=$(date +%Y-%m-%d)
        
        if [[ -f "$lock_file" ]]; then
            status="LOCKED"
            if command -v jq &>/dev/null; then
                artifact=$(jq -r '.artifact // ""' "$lock_file" 2>/dev/null || echo "")
                last_date=$(jq -r '.locked_at // ""' "$lock_file" 2>/dev/null | cut -d_ -f1 || echo "$last_date")
            fi
        fi
        
        update_matrix_entry "$script_rel" "$status" "$artifact"
    done
    
    # Populate downstream dependents
    if command -v jq &>/dev/null; then
        local tmp_file
        tmp_file=$(mktemp)
        
        # For each script, find who depends on it
        for script in "${!UPSTREAM_DEPS[@]}"; do
            IFS=' ' read -ra deps <<< "${UPSTREAM_DEPS[$script]}"
            for dep in "${deps[@]}"; do
                [[ -z "$dep" ]] && continue
                jq --arg script "$script" \
                   --arg dep "$dep" \
                   'if .[$dep] then .[$dep].downstream_dependents += [$script] | .[$dep].downstream_dependents |= unique else . end' \
                   "$MATRIX_FILE" > "$tmp_file"
                mv "$tmp_file" "$MATRIX_FILE"
            done
        done
    fi
    
    echo "✅ Matrix updated: $MATRIX_FILE"
    
    if command -v jq &>/dev/null; then
        echo ""
        echo "--- Matrix Summary ---"
        jq -r 'to_entries | .[] | "\(.key): \(.value.status)"' "$MATRIX_FILE"
    fi
}

# ============================================================================
# SHOW STATUS FUNCTION
# ============================================================================
do_status() {
    echo "📋 Lock Status Summary"
    echo "======================"
    
    local locked=0
    local unlocked=0
    
    for script in "$ROOT_DIR"/scripts/[0-9][0-9]_build_*.sh; do
        [[ -f "$script" ]] || continue
        local script_name
        script_name=$(basename "$script")
        local lock_file
        lock_file=$(get_lock_file "$script")
        
        if [[ -f "$lock_file" ]]; then
            echo "🔒 $script_name"
            locked=$((locked + 1))
        else
            echo "   $script_name"
            unlocked=$((unlocked + 1))
        fi
    done
    
    echo ""
    echo "Total: $locked locked, $unlocked unlocked"
}

# ============================================================================
# HELP FUNCTION
# ============================================================================
show_help() {
    cat << 'EOF'
Lock Manager — Shell Script Governance Utility

USAGE:
    ./scripts/lock_manager.sh <command> [arguments]

COMMANDS:
    --lock <script_path>      Lock a script (creates backup + lock file)
    --unlock <script_path>    Unlock a script (removes lock file)
    --check <script_path>     Check if script is locked (exit 0=unlocked, 1=locked)
    --scan-artifacts          Auto-lock scripts based on existing artifacts
    --update-matrix           Regenerate dependency_matrix.json
    --status                  Show lock status of all build scripts
    --help                    Show this help message

SOURCEABLE FUNCTIONS:
    source scripts/lock_manager.sh
    check_lock "$0" || { echo "Script is LOCKED"; exit 1; }
    lock_script "$0" "artifact_name.whl"

EXAMPLES:
    # Lock after successful build
    ./scripts/lock_manager.sh --lock scripts/20_build_pytorch_rocm.sh

    # Check if locked before editing
    ./scripts/lock_manager.sh --check scripts/20_build_pytorch_rocm.sh

    # Auto-lock all scripts with existing artifacts
    ./scripts/lock_manager.sh --scan-artifacts

EOF
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================
# Only run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --lock)
            [[ -z "${2:-}" ]] && { echo "Error: script path required"; exit 1; }
            do_lock "$2" "${3:-}"
            ;;
        --unlock)
            [[ -z "${2:-}" ]] && { echo "Error: script path required"; exit 1; }
            do_unlock "$2"
            ;;
        --check)
            [[ -z "${2:-}" ]] && { echo "Error: script path required"; exit 1; }
            do_check "$2"
            ;;
        --scan-artifacts)
            do_scan_artifacts
            ;;
        --update-matrix)
            do_update_matrix
            ;;
        --status)
            do_status
            ;;
        --help|-h|"")
            show_help
            ;;
        *)
            echo "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
fi
