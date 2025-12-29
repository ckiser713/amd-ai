#!/usr/bin/env bash
# scripts/silent_build_runner.sh
# Token-efficient autonomous build repairs for AMD AI Stack.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

LOG_DIR="logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
FULL_LOG="$LOG_DIR/build_${TIMESTAMP}.log"
ERROR_LOG="$LOG_DIR/error.log"
CHANGE_LOG="change.log"

# =========================================================================
# PRE-FLIGHT CHECK: Verify change.log status before starting
# =========================================================================
if [[ -f "$CHANGE_LOG" ]]; then
    # Extract last status entry (handles both "Status:" and "**Status**:" formats)
    LAST_STATUS=$(grep -E "^\*\*Status\*\*:|^Status:" "$CHANGE_LOG" | tail -1 | sed 's/.*: *//')
    if [[ "$LAST_STATUS" == *"IN_PROGRESS"* ]]; then
        echo "⚠️  WARNING: An agent is currently working (Status: IN_PROGRESS)"
        echo "   Check change.log before proceeding to avoid conflicts."
        echo "   File: $(readlink -f "$CHANGE_LOG")"
    fi
fi

# Execute full build pipeline silently
# Remove git locks to prevent zombie lock issues
rm -f .git/index.lock .git/modules/**/index.lock
# Use --skip to preserve patched source files (prefetch resets them)
# Run prefetch manually with: ./scripts/06_prefetch_all_dependencies.sh before first build
./scripts/80_run_complete_build_docker.sh --skip > "$FULL_LOG" 2>&1
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "complete"
    exit 0
else
    echo "failure"
    {
        echo "=== FAIL: $TIMESTAMP ==="
        echo "Log: $FULL_LOG"
        echo "Code: $EXIT_CODE"
        echo -e "\n--- DETECTED ERROR PATTERNS ---"
        # Grep for fatal errors, python tracebacks, or pip conflicts
        grep -Ei "(error|failure|conflict|denied|missing|not found|traceback|nvidia|cuda)" "$FULL_LOG" | tail -n 20
        echo -e "\n--- TAIL 250 ---"
        tail -n 250 "$FULL_LOG"
    } > "$ERROR_LOG"
    
    # =========================================================================
    # ERROR LOG ARCHIVAL: Synchronize with build log timestamp for traceability
    # =========================================================================
    # Extract timestamp from the build log filename to ensure 1:1 mapping
    ARCHIVE_TIMESTAMP=$(basename "$FULL_LOG" | sed 's/^build_//; s/\.log$//')
    ARCHIVED_ERROR="$LOG_DIR/error_${ARCHIVE_TIMESTAMP}.log"
    
    if [[ -s "$ERROR_LOG" ]]; then
        # Copy error.log to timestamped archive for historical debugging
        cp "$ERROR_LOG" "$ARCHIVED_ERROR"
        echo "📦 Archived: $ARCHIVED_ERROR"
    fi
    
    echo "Investigate: $(readlink -f "$ERROR_LOG")"
    
    # =========================================================================
    # POST-FAILURE HOOK: Append agent-required template to change.log
    # =========================================================================
    {
        echo ""
        echo "## [Agent-Required] | $(date '+%Y-%m-%d %H:%M')"
        echo "**Status**: BROKEN"
        echo "**Error Reported**: Build failed with exit code $EXIT_CODE"
        echo "**Files Implicated**: See logs/error.log"
        echo "**Deep Dive Findings**: (pending agent analysis)"
        echo "**Applied Fix**: (pending)"
        echo "**Recommendation**: Run \`cat logs/error.log\` and investigate"
        echo "**ESTIMATED TOKEN USAGE**: (pending)"
        echo "**End Time**: (pending)"
    } >> "$CHANGE_LOG"
    echo "📋 Appended repair request to change.log"
    
    # =========================================================================
    # ANTIGRAVITY REPAIR INSTRUCTIONS FOR AI AGENT
    # =========================================================================
    # 1. READ: Inspect logs/error.log.
    # 2. LOG: Sign into change.log with a random name and Start Time.
    # 3. ANALYZE: Conduct deep analysis of files identified in the error.
    # 4. REPAIR: Apply fixes (Ensure you prioritize artifacts over PyPI).
    # 5. COST: Log token usage and estimated cost in change.log.
    # 6. RETRY: Re-execute this script: ./scripts/silent_build_runner.sh
    # 7. ESCALATE: If failure persists after 3 attempts, halt and notify user.
    # =========================================================================
    
    exit 1
fi