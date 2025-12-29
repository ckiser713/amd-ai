#!/usr/bin/env bash
# scripts/tests/test_parallel_env.sh
# Unit tests for scripts/parallel_env.sh logic

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# We need to source parallel_env.sh, but we want to capture its output/state
# independent of the current shell's state in some cases.
# We will use subshells for each test case.

PARALLEL_ENV_PATH="$ROOT_DIR/scripts/parallel_env.sh"

fail() {
    echo "❌ FAIL: $1"
    exit 1
}

pass() {
    echo "✅ PASS: $1"
}

echo "=== Testing parallel_env.sh logic ==="

# Test 1: Default behavior (force mode default, no env vars set)
# Should calculate jobs > 1 (assuming multi-core machine)
(
    unset MAX_JOBS PARALLEL_MODE PARALLEL_JOBS MAKEFLAGS
    source "$PARALLEL_ENV_PATH"
    apply_parallel_env
    
    if [[ "$MAX_JOBS" -le 1 ]]; then
        # Unless single-core machine?
        cores=$(nproc)
        if [[ "$cores" -gt 1 ]]; then
            fail "Default mode on multi-core machine gave MAX_JOBS=$MAX_JOBS (expected > 1)"
        fi
    fi
    pass "Default behavior (resolved to $MAX_JOBS)"
) || exit 1

# Test 2: Inherited single-core with FORCE mode (Default)
# Should override MAX_JOBS=1
(
    export MAX_JOBS=1
    unset PARALLEL_MODE
    source "$PARALLEL_ENV_PATH"
    apply_parallel_env
    
    cores=$(nproc)
    if [[ "$cores" -gt 1 ]]; then
        if [[ "$MAX_JOBS" -eq 1 ]]; then
            fail "Force mode (default) failed to override MAX_JOBS=1 (got $MAX_JOBS)"
        fi
    fi
    pass "Force mode overrides inherited MAX_JOBS=1 (got $MAX_JOBS)"
) || exit 1

# Test 3: Inherited single-core with RESPECT mode
# Should keep MAX_JOBS=1
(
    export MAX_JOBS=1
    export PARALLEL_MODE=respect
    source "$PARALLEL_ENV_PATH"
    apply_parallel_env
    
    if [[ "$MAX_JOBS" -ne 1 ]]; then
        fail "Respect mode failed to preserve MAX_JOBS=1 (got $MAX_JOBS)"
    fi
    pass "Respect mode preserved MAX_JOBS=1"
) || exit 1

# Test 4: Pin mode
# Should set MAX_JOBS to PARALLEL_JOBS
(
    export PARALLEL_MODE=pin
    export PARALLEL_JOBS=13
    source "$PARALLEL_ENV_PATH"
    apply_parallel_env
    
    if [[ "$MAX_JOBS" -ne 13 ]]; then
        fail "Pin mode failed to set MAX_JOBS=13 (got $MAX_JOBS)"
    fi
    if [[ "$MAKEFLAGS" != *"-j13"* ]]; then
        fail "Pin mode failed to set MAKEFLAGS -j13 (got $MAKEFLAGS)"
    fi
    pass "Pin mode set MAX_JOBS=13"
) || exit 1

# Test 5: Pin mode with fallback (MAX_JOBS set, PARALLEL_JOBS unset)
# Should use MAX_JOBS as the pin value
(
    export PARALLEL_MODE=pin
    export MAX_JOBS=5
    unset PARALLEL_JOBS
    source "$PARALLEL_ENV_PATH"
    apply_parallel_env
    
    if [[ "$MAX_JOBS" -ne 5 ]]; then
        fail "Pin mode fallback failed (got $MAX_JOBS, expected 5)"
    fi
    pass "Pin mode fallback used MAX_JOBS=5"
) || exit 1

# Test 6: Makeflags cleanup
# Should remove existing -j flags before appending new one
(
    export PARALLEL_MODE=force
    export MAKEFLAGS="-j1 --silent"
    source "$PARALLEL_ENV_PATH"
    apply_parallel_env
    
    # We expect -j(calculated) to be present, and -j1 to be GONE or overridden
    # Simple check: the LAST -j should be our calculated one, or -j1 should be gone.
    # Our implementation should remove -j1.
    
    if [[ "$MAKEFLAGS" == *"-j1 "* ]] || [[ "$MAKEFLAGS" == *"-j1" ]]; then
        fail "Makeflags cleanup failed, -j1 still present: '$MAKEFLAGS'"
    fi
    pass "Makeflags cleaned up (-j1 removed): '$MAKEFLAGS'"
) || exit 1

echo "All tests passed!"
exit 0
