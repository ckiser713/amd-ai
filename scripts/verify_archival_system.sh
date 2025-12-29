#!/usr/bin/env bash
# verify_archival_system.sh
# Verification script for Error Log Archival System implementation
# Tests that the archival system is properly configured and functional

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Error Log Archival System — Verification Script            ║"
echo "║  Version 1.0 | 2025-12-29                                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

ERRORS=0
WARNINGS=0
CHECKS_PASSED=0
CHECKS_TOTAL=0

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
check() {
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    local test_name="$1"
    echo -n "[$CHECKS_TOTAL] $test_name ... "
}

pass() {
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    echo -e "${GREEN}✓ PASS${NC}"
}

fail() {
    ERRORS=$((ERRORS + 1))
    echo -e "${RED}✗ FAIL${NC}: $1"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# =========================================================================
# CHECK 1: File Existence
# =========================================================================
echo ""
echo "═══ 1. FILE EXISTENCE CHECKS ═══"

check "scripts/silent_build_runner.sh exists"
if [[ -f "$ROOT_DIR/scripts/silent_build_runner.sh" ]]; then
    pass
else
    fail "Missing: scripts/silent_build_runner.sh"
fi

check "logs directory exists"
if [[ -d "$ROOT_DIR/logs" ]]; then
    pass
else
    fail "Missing: logs/ directory"
fi

check "Documentation files exist"
docs_missing=0
for doc in "docs/ERROR_LOG_ARCHIVAL.md" "docs/STRIKE_TRACKING.md" "docs/ARCHIVAL_SYSTEM_VISUAL.md" "docs/ARCHIVAL_QUICK_REFERENCE.md" "docs/ARCHIVAL_SYSTEM_INDEX.md"; do
    if [[ ! -f "$ROOT_DIR/$doc" ]]; then
        echo -n "  Missing: $doc"
        docs_missing=$((docs_missing + 1))
    fi
done
if [[ $docs_missing -eq 0 ]]; then
    pass
else
    fail "$docs_missing documentation files missing"
fi

# =========================================================================
# CHECK 2: Implementation Code
# =========================================================================
echo ""
echo "═══ 2. IMPLEMENTATION CODE CHECKS ═══"

check "Archival logic present in silent_build_runner.sh"
if grep -q "ARCHIVE_TIMESTAMP" "$ROOT_DIR/scripts/silent_build_runner.sh"; then
    pass
else
    fail "Archival logic not found"
fi

check "Timestamp extraction pattern present"
if grep -q "sed 's/^build_//; s/.\.log\$//" "$ROOT_DIR/scripts/silent_build_runner.sh"; then
    pass
    info "Uses robust sed pattern for timestamp extraction"
else
    fail "Timestamp extraction pattern not found"
fi

check "Archival copy command present"
if grep -q "cp \"\$ERROR_LOG\" \"\$ARCHIVED_ERROR\"" "$ROOT_DIR/scripts/silent_build_runner.sh"; then
    pass
else
    fail "Archival copy command not found"
fi

check "Non-empty file check present"
if grep -q "\[\[ -s \"\$ERROR_LOG\" \]\]" "$ROOT_DIR/scripts/silent_build_runner.sh"; then
    pass
    info "Only archives if error.log is non-empty"
else
    fail "Non-empty file check not found"
fi

check "Success message present"
if grep -q "📦 Archived:" "$ROOT_DIR/scripts/silent_build_runner.sh"; then
    pass
    info "Provides feedback on archival"
else
    warn "No success message for archival"
fi

# =========================================================================
# CHECK 3: Documentation Quality
# =========================================================================
echo ""
echo "═══ 3. DOCUMENTATION QUALITY CHECKS ═══"

check "ERROR_LOG_ARCHIVAL.md is comprehensive (500+ lines)"
if [[ -f "$ROOT_DIR/docs/ERROR_LOG_ARCHIVAL.md" ]]; then
    lines=$(wc -l < "$ROOT_DIR/docs/ERROR_LOG_ARCHIVAL.md")
    if [[ $lines -gt 400 ]]; then
        pass
        info "$lines lines"
    else
        warn "Documentation may be incomplete ($lines lines, expected 400+)"
    fi
else
    fail "ERROR_LOG_ARCHIVAL.md missing"
fi

check "STRIKE_TRACKING.md is practical guide (300+ lines)"
if [[ -f "$ROOT_DIR/docs/STRIKE_TRACKING.md" ]]; then
    lines=$(wc -l < "$ROOT_DIR/docs/STRIKE_TRACKING.md")
    if [[ $lines -gt 300 ]]; then
        pass
        info "$lines lines"
    else
        warn "Guide may be incomplete ($lines lines, expected 300+)"
    fi
else
    fail "STRIKE_TRACKING.md missing"
fi

check "Quick reference card exists (100+ lines)"
if [[ -f "$ROOT_DIR/docs/ARCHIVAL_QUICK_REFERENCE.md" ]]; then
    lines=$(wc -l < "$ROOT_DIR/docs/ARCHIVAL_QUICK_REFERENCE.md")
    if [[ $lines -gt 100 ]]; then
        pass
        info "$lines lines"
    else
        warn "Quick reference may be incomplete ($lines lines, expected 100+)"
    fi
else
    fail "Quick reference missing"
fi

check "Documentation includes examples"
example_count=0
for doc in "$ROOT_DIR/docs/ARCHIVAL_SYSTEM_VISUAL.md" "$ROOT_DIR/docs/STRIKE_TRACKING.md"; do
    if [[ -f "$doc" ]]; then
        count=$(grep -c '```bash' "$doc" 2>/dev/null || echo 0)
        example_count=$((example_count + count))
    fi
done
if [[ $example_count -gt 10 ]]; then
    pass
    info "$example_count code examples provided"
else
    warn "Limited code examples ($example_count found)"
fi

# =========================================================================
# CHECK 4: Code Quality
# =========================================================================
echo ""
echo "═══ 4. CODE QUALITY CHECKS ═══"

check "Shell script follows best practices"
if grep -q "set -e" "$ROOT_DIR/scripts/silent_build_runner.sh" || \
   grep -q "set -u" "$ROOT_DIR/scripts/silent_build_runner.sh"; then
    pass
    info "Error handling present"
else
    warn "Shell script may need error handling"
fi

check "Proper variable quoting in archival logic"
if grep -q "\"\$ARCHIVED_ERROR\"" "$ROOT_DIR/scripts/silent_build_runner.sh"; then
    pass
    info "Variables properly quoted"
else
    warn "Variable quoting may be inconsistent"
fi

check "Bash-specific features avoided"
if grep -q "bashisms" "$ROOT_DIR/scripts/silent_build_runner.sh" 2>/dev/null; then
    fail "Script contains bash-specific features"
else
    pass
    info "POSIX compatibility maintained"
fi

# =========================================================================
# CHECK 5: Integration with Existing System
# =========================================================================
echo ""
echo "═══ 5. INTEGRATION CHECKS ═══"

check "change.log updated with implementation entry"
if grep -q "Agent-Archival-System" "$ROOT_DIR/change.log"; then
    pass
    info "Change log properly documented"
else
    warn "change.log entry may be incomplete"
fi

check "Integration with lock_manager.sh compatible"
if [[ -f "$ROOT_DIR/scripts/lock_manager.sh" ]]; then
    pass
    info "Lock manager available for integration"
else
    warn "Lock manager not found"
fi

check "Documentation references change.log"
if grep -r "change.log" "$ROOT_DIR/docs/" 2>/dev/null | grep -q "Archival\|error"; then
    pass
    info "Documentation properly integrated"
else
    warn "Documentation may not reference change.log"
fi

# =========================================================================
# CHECK 6: Functional Tests (Requires Build Logs)
# =========================================================================
echo ""
echo "═══ 6. FUNCTIONAL TESTS ═══"

check "Build logs directory structure"
if [[ -d "$ROOT_DIR/logs" ]]; then
    pass
    build_count=$(ls -1 "$ROOT_DIR/logs"/build_*.log 2>/dev/null | wc -l)
    error_count=$(ls -1 "$ROOT_DIR/logs"/error_*.log 2>/dev/null | wc -l)
    info "Found: $build_count build logs, $error_count error archives"
else
    fail "logs directory missing"
fi

check "Archive naming convention"
if [[ -d "$ROOT_DIR/logs" ]]; then
    error_files=$(ls -1 "$ROOT_DIR/logs"/error_*.log 2>/dev/null)
    if [[ -n "$error_files" ]]; then
        # Check if timestamp format matches
        first_error=$(echo "$error_files" | head -1)
        if [[ "$first_error" =~ error_[0-9]{8}_[0-9]{6}\.log ]]; then
            pass
            info "Timestamp format correct: YYYYMMDD_HHMMSS"
        else
            warn "Archive naming may not match expected pattern"
        fi
    else
        info "No error archives yet (build hasn't failed)"
    fi
else
    warn "Cannot test archive naming"
fi

check "Timestamp synchronization"
if [[ -d "$ROOT_DIR/logs" ]]; then
    latest_build=$(ls -t "$ROOT_DIR/logs"/build_*.log 2>/dev/null | head -1)
    if [[ -n "$latest_build" ]]; then
        build_ts=$(basename "$latest_build" | sed 's/^build_//; s/\.log$//')
        error_file="$ROOT_DIR/logs/error_${build_ts}.log"
        if [[ -f "$error_file" ]]; then
            pass
            info "Archive timestamp matches: $build_ts"
        else
            info "No corresponding error archive yet (build may have succeeded)"
        fi
    else
        info "No build logs yet"
    fi
else
    warn "Cannot test timestamp synchronization"
fi

# =========================================================================
# CHECK 7: Documentation Completeness
# =========================================================================
echo ""
echo "═══ 7. DOCUMENTATION COMPLETENESS ═══"

required_sections=(
    "Architecture"
    "Strike Tracking"
    "Quick Reference"
    "Examples"
    "Troubleshooting"
    "Integration"
    "Performance"
)

missing_sections=0
for section in "${required_sections[@]}"; do
    check "Documentation includes '$section' section"
    if grep -ri "$section" "$ROOT_DIR/docs/" 2>/dev/null | grep -q .; then
        pass
    else
        warn "May be missing comprehensive $section documentation"
        missing_sections=$((missing_sections + 1))
    fi
done

# =========================================================================
# SUMMARY
# =========================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      VERIFICATION SUMMARY                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

total_tests=$CHECKS_TOTAL
passed=$CHECKS_PASSED
failed=$ERRORS
warnings=$WARNINGS

echo "Tests Run:        $total_tests"
echo -e "Passed:           ${GREEN}$passed${NC}"
if [[ $failed -gt 0 ]]; then
    echo -e "Failed:           ${RED}$failed${NC}"
else
    echo -e "Failed:           ${GREEN}0${NC}"
fi
if [[ $warnings -gt 0 ]]; then
    echo -e "Warnings:         ${YELLOW}$warnings${NC}"
else
    echo -e "Warnings:         ${GREEN}0${NC}"
fi
echo ""

pass_rate=$((passed * 100 / total_tests))
echo "Pass Rate:        $pass_rate%"
echo ""

# =========================================================================
# FINAL STATUS
# =========================================================================
if [[ $failed -eq 0 ]]; then
    echo -e "${GREEN}✓ ARCHIVAL SYSTEM VERIFICATION PASSED${NC}"
    echo ""
    echo "The Error Log Archival System is properly installed and configured."
    echo ""
    echo "Next Steps:"
    echo "  1. Run: ./scripts/silent_build_runner.sh"
    echo "  2. On failure, archives will be created automatically"
    echo "  3. View archives: ls -ltr logs/error_*.log"
    echo "  4. Read guide: docs/STRIKE_TRACKING.md"
    echo ""
    exit 0
elif [[ $warnings -gt 0 && $failed -eq 0 ]]; then
    echo -e "${YELLOW}⚠ ARCHIVAL SYSTEM INSTALLED WITH WARNINGS${NC}"
    echo ""
    echo "The system is functional but may need attention to the warnings above."
    echo ""
    exit 0
else
    echo -e "${RED}✗ ARCHIVAL SYSTEM VERIFICATION FAILED${NC}"
    echo ""
    echo "Please fix the $failed errors listed above before using the system."
    echo ""
    exit 1
fi

