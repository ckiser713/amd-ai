# Strike Tracking Protocol — Error Log Correlation Guide

## Quick Start

The Error Log Archival System enables **Strike Tracking**: correlating repeated build failures across multiple attempts to identify and fix root causes.

### TL;DR
```bash
# View all strikes (errors) in chronological order
ls -ltr build_logs/error_*.log

# Read most recent strike
cat build_logs/error_*.log | tail -1 | xargs cat

# Compare Strike 2 vs Strike 5 to see if fix worked
diff build_logs/error_20251229_185530.log build_logs/error_20251229_190445.log

# Find all OOM errors (exit code 137)
grep "Code: 137" build_logs/error_*.log

# Find all xformers-related errors
grep -l "xformers" build_logs/error_*.log
```

## Terminology

| Term | Definition |
|------|-----------|
| **Strike** | One complete build failure cycle (from `./scripts/silent_build_runner.sh` exit with code ≠ 0) |
| **Archive** | Timestamped error snapshot: `error_YYYYMMDD_HHMMSS.log` |
| **Pattern** | Extracted error keywords (error, failure, conflict, missing, traceback, etc.) |
| **Exit Code** | Process termination code (0=success, 1=generic, 137=OOM, 128=signal) |
| **Root Cause** | The underlying problem (xformers parallelism, git lock, CUDA, etc.) |

## Strike Tracking Workflow

### Phase 1: Initial Failure (Strike 1)

```bash
$ cd /home/nexus/amd-ai && ./scripts/silent_build_runner.sh
failure
📦 Archived: build_logs/error_20251229_185215.log
Investigate: /home/nexus/amd-ai/error.log
```

**Output files created**:
- `build_logs/build_20251229_185215.log` — Full 139MB build output
- `build_logs/error_20251229_185215.log` — Curated error snapshot (~5-20MB)
- `error.log` — Active error file (used for immediate inspection)

**Inspection**:
```bash
$ cat error.log
=== FAIL: 20251229_185215 ===
Log: build_logs/build_20251229_185215.log
Code: 137

--- DETECTED ERROR PATTERNS ---
ninja: error: ...
xformers: out of memory

--- TAIL 50 ---
[last 50 lines of build]
```

**Analysis**:
- Exit code **137** = Out of Memory (OOM)
- Pattern: **xformers** mentioned in errors
- Hypothesis: Xformers parallel build is consuming too much memory

### Phase 2: Apply Fix (Agent Work)

Agent reviews `error_20251229_185215.log` and implements a fix:

```markdown
## Agent-Debug-1 | 2025-12-29 18:50
**Status**: IN_PROGRESS
**Error Reported**: Build failed with exit code 137 (OOM during xformers)
**Files Implicated**: build_logs/error_20251229_185215.log
**Deep Dive Findings**: 
  - Exit code 137 = Out of memory
  - Xformers build using full -j128 parallelism
  - 128GB system but compiler cache + linking consuming 140GB+ virtual memory
**Applied Fix**: 
  - Reduced MAX_JOBS from 128 to 96 in parallel_env.sh for xformers
  - Implemented LLD linker (faster, lower memory)
  - Enable ccache to reduce redundant compilation
**Recommendation**: Rerun silent build runner
**End Time**: 2025-12-29 18:51
```

### Phase 3: Retry Build (Strike 2)

```bash
$ cd /home/nexus/amd-ai && ./scripts/silent_build_runner.sh
failure
📦 Archived: build_logs/error_20251229_185530.log
Investigate: /home/nexus/amd-ai/error.log
```

**New files**:
- `build_logs/build_20251229_185530.log` — Second build attempt
- `build_logs/error_20251229_185530.log` — Second error archive
- `error.log` — Updated with new errors

### Phase 4: Verify Fix (Comparison)

```bash
$ diff build_logs/error_20251229_185215.log build_logs/error_20251229_185530.log

< Code: 137
---
> Code: 1

# Strike 1: OOM (137) → Strike 2: Generic failure (1) = Progress!
# But still failing, need deeper investigation
```

**Interpretation**:
- ✅ OOM fixed (137 → 1)
- ❌ Different error now (likely next bottleneck)
- 📊 Continue to Strike 3

### Phase 5: Iterate Until Success

**Strike 3**: Fix linker issues
**Strike 4**: Fix git lock race condition  
**Strike 5**: Fix xformers constexpr compilation  
**Strike 6**: ✅ **COMPLETE** (`./scripts/silent_build_runner.sh` returns "complete")

## Common Strike Patterns

### Pattern 1: OOM (Exit Code 137)
```bash
$ grep "Code: 137" build_logs/error_*.log
build_logs/error_20251229_185215.log:Code: 137
build_logs/error_20251229_185530.log:Code: 137

# Repeated OOM = parallelism too aggressive
# Solution: Reduce MAX_JOBS in parallel_env.sh
```

**Debugging**:
```bash
$ cat build_logs/error_20251229_185215.log | grep -A5 "TAIL 50" | tail -20
# Look for: "ninja: error: link.exe: out of memory"
# Or: "cc1plus: fatal error: error writing to /tmp: No space left on device"
```

### Pattern 2: Git Locks (Exit Code 128)
```bash
$ grep "Code: 128" build_logs/error_*.log
build_logs/error_20251229_185945.log:Code: 128

$ grep "git.*lock" build_logs/error_*.log
fatal: Unable to create '.git/objects/info/commit-graphs/commit-graph-chain.lock'
```

**Fix**:
```bash
find src/extras -name ".git" -type d -exec rm -rf {}/.git/objects/info/commit-graphs/*.lock \;
```

### Pattern 3: CUDA Detection (Exit Code 1)
```bash
$ grep -i "cuda\|nvidia" build_logs/error_*.log
build_logs/error_20251229_190201.log:ERROR: NVIDIA/CUDA detected in build dependencies
```

**Fix**: This violates AGENTS.md Rule 5. Halt and escalate.

### Pattern 4: Compilation Errors (Exit Code 1)
```bash
$ grep "error:" build_logs/error_*.log | head -10
error: constexpr variable 'warpSize' must be initialized by a constant expression
```

**Fix**: Patch source files in `src/extras/*/`. Update patches in `scripts/internal_container_build.sh`.

## Strike Correlation Commands

### Find Related Strikes
```bash
# All xformers-related failures
grep -l "xformers" build_logs/error_*.log | sort

# All OOM failures
grep "Code: 137" build_logs/error_*.log | awk -F: '{print $1}' | sort

# Failures within last 2 hours
find build_logs/error_*.log -mmin -120 -type f
```

### Timeline View
```bash
# Show chronological sequence with exit codes
for f in $(ls -tr build_logs/error_*.log); do
    echo "$(basename "$f") → Exit: $(grep 'Code:' "$f" | cut -d' ' -f2)"
done

# Output:
# error_20251229_185215.log → Exit: 137
# error_20251229_185530.log → Exit: 137
# error_20251229_185945.log → Exit: 1
# error_20251229_190201.log → Exit: 1
# error_20251229_190445.log → Exit: 0 (Success!)
```

### Success Detection
```bash
# Grep for "complete" in build runner output
tail -1 build_logs/build_*.log | xargs grep -l "complete"

# Or check silent_build_runner exit code history:
ls -ltr build_logs/ | grep -v error  # Last file should be build_*.log (not error)
```

## Advanced Analysis

### Extract Error Patterns Across All Strikes
```bash
echo "=== Error Pattern Frequency Across All Strikes ==="
for f in build_logs/error_*.log; do
    echo "=== $(basename "$f") ==="
    grep "DETECTED ERROR PATTERNS" -A 20 "$f" | grep -v "^--$" | sort | uniq -c | sort -rn
done
```

### Build Time Trending
```bash
# How long did each build take?
for buildfile in $(ls -tr build_logs/build_*.log); do
    lines=$(wc -l < "$buildfile")
    timestamp=$(basename "$buildfile" | sed 's/build_//; s/\.log//')
    echo "$timestamp: $lines lines"
done
```

### Memory Usage Estimation
```bash
# Error archive size = approximation of error complexity
ls -lhS build_logs/error_*.log | awk '{print $5, $9}' | column -t
```

## Integration with change.log

Every Strike Tracking session should be documented in `change.log`:

```markdown
## Agent-Strike-Tracker | 2025-12-29 18:50
**Status**: IN_PROGRESS
**Strike Count**: 5 (aiming for 0)
**Error Timeline**:
  - Strike 1: Exit 137 (OOM) — xformers parallelism
  - Strike 2: Exit 137 (OOM) — parallel_env.sh adjusted
  - Strike 3: Exit 1 (compilation) — xformers ck_tile constexpr
  - Strike 4: Exit 128 (git lock) — stale lock files
  - Strike 5: Exit 0 (SUCCESS) ✅

**Root Causes Fixed**:
1. Reduced parallelism for 128GB systems to 96 jobs
2. Patched xformers ck_tile constexpr issues
3. Added git lock cleanup on prefetch

**Artifacts Preserved**:
- build_logs/error_20251229_*.log (all archived)
- change.log entry with complete timeline
- All patches applied to scripts/

**Recommendation**: Lock successful scripts and verify artifacts
**End Time**: 2025-12-29 18:58
```

## Troubleshooting Strike Tracking

### Issue: Unclear what changed between strikes
**Solution**: Run diff
```bash
diff build_logs/error_strike2.log build_logs/error_strike5.log
```

### Issue: Archives growing too large
**Solution**: Compress old archives
```bash
tar czf backups/error_logs_first_10_strikes.tar.gz build_logs/error_*.log
rm build_logs/error_*.log
```

### Issue: Lost track of which strike we're on
**Solution**: Count archives
```bash
ls build_logs/error_*.log | wc -l  # Total strikes
ls -ltr build_logs/error_*.log | tail -1  # Most recent strike
```

## Summary

The Error Log Archival System enables:

✅ **Traceability**: 1:1 mapping between builds and error snapshots  
✅ **Efficiency**: Token-efficient debugging (5-20MB archives vs 139MB primary logs)  
✅ **Automation**: Strike Tracking without manual intervention  
✅ **Protocol Compliance**: Agents debug via archives, not primary logs  
✅ **History**: Complete timeline of all failures and fixes  

**Next Steps**:
1. Run `./scripts/silent_build_runner.sh`
2. On failure: Inspect `build_logs/error_YYYYMMDD_HHMMSS.log`
3. Update `change.log` with findings
4. Apply fixes
5. Repeat until "complete"

