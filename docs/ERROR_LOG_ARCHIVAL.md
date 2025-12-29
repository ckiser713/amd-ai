# Error Log Archival System — Strike Tracking Protocol

## Overview

The **Error Log Archival System** provides synchronized, timestamped error capture for the AMD AI autonomous build system. Every build failure generates a unique error snapshot that is automatically paired with its corresponding build log, enabling fast correlation and debugging.

## Problem Statement

Without archival, `error.log` gets overwritten on each build failure, losing historical context needed for:
- **Strike Tracking**: Debugging recurring failures across multiple build attempts
- **Pattern Analysis**: Identifying root causes across multiple strikes
- **Regression Testing**: Verifying that fixes actually resolved the issue
- **/execute_silent Protocol Compliance**: Agents can inspect `error_TIMESTAMP.log` without violating the "no direct build log reading" rule

## Architecture

### File Structure
```
build_logs/
├── build_20251229_185215.log      # Full build output
├── error_20251229_185215.log      # Timestamped error snapshot
├── build_20251229_185530.log      # Next attempt
├── error_20251229_185530.log      # Next attempt's errors
└── ... (Strike history)
```

### 1:1 Mapping Guarantee
Every error archive **exactly matches** its corresponding build log timestamp:
- Build log: `build_YYYYMMDD_HHMMSS.log`
- Error archive: `error_YYYYMMDD_HHMMSS.log`

This ensures zero ambiguity when correlating failures to their root causes.

## Implementation Details

### Location
**File**: `scripts/silent_build_runner.sh` (lines 50-61)

### Logic Flow

```bash
# 1. Build executes and generates build_YYYYMMDD_HHMMSS.log
./scripts/80_run_complete_build_docker.sh > "$FULL_LOG" 2>&1
EXIT_CODE=$?

# 2. On failure, error patterns extracted to error.log
{
    # ... error pattern extraction ...
} > "$ERROR_LOG"

# 3. Extract timestamp from build log filename
ARCHIVE_TIMESTAMP=$(basename "$FULL_LOG" | sed 's/^build_//; s/\.log$//')
# Result: "20251229_185215"

# 4. Create timestamped archive
ARCHIVED_ERROR="$LOG_DIR/error_${ARCHIVE_TIMESTAMP}.log"

# 5. Copy error.log to archive (only if non-empty)
if [[ -s "$ERROR_LOG" ]]; then
    cp "$ERROR_LOG" "$ARCHIVED_ERROR"
fi
```

### Timestamp Extraction Pattern
```bash
sed 's/^build_//; s/\.log$//'
```

**Input**: `build_logs/build_20251229_185215.log`
**Output**: `20251229_185215`

This robust pattern:
- ✅ Strips `build_` prefix
- ✅ Strips `.log` suffix
- ✅ Preserves exact YYYYMMDD_HHMMSS format
- ✅ Works with any directory path

## Error Log Contents

Each `error_YYYYMMDD_HHMMSS.log` contains:

```
=== FAIL: 20251229_185215 ===
Log: build_logs/build_20251229_185215.log
Code: 137

--- DETECTED ERROR PATTERNS ---
[Up to 20 lines matching: error|failure|conflict|denied|missing|not found|traceback|nvidia|cuda]

--- TAIL 50 ---
[Last 50 lines of full build log]
```

This format provides:
- **Timestamp Context**: YYYYMMDD_HHMMSS
- **Exit Code**: Process termination code (137 = OOM, 1 = generic failure, etc.)
- **Pattern Summary**: Extracted error keywords for quick scanning
- **Full Tail**: Last 50 lines for detailed context

## Strike Tracking Integration

### Usage Example: Strike 3 Debugging

```bash
$ ls -ltr build_logs/error_*.log | tail -5
-rw-r--r-- error_20251229_185215.log  # Strike 1
-rw-r--r-- error_20251229_185530.log  # Strike 2
-rw-r--r-- error_20251229_185945.log  # Strike 3
-rw-r--r-- error_20251229_190201.log  # Strike 4
-rw-r--r-- error_20251229_190445.log  # Strike 5

$ cat build_logs/error_20251229_185945.log
# Now you have Strike 3's exact error state without needing to read the primary 139MB build log
```

### Pattern Analysis Workflow

```bash
# Find all OOM failures (exit code 137)
grep "Code: 137" build_logs/error_*.log

# Find all CUDA-related errors (catches anti-NVIDIA violations)
grep -l "cuda\|nvidia" build_logs/error_*.log

# Compare errors across strikes
diff build_logs/error_strike2.log build_logs/error_strike3.log

# Timeline view
for f in build_logs/error_*.log; do
    echo "=== $f ==="
    grep "Code:" "$f"
done
```

## Protocol Compliance

### /execute_silent Rules
✅ **ALLOWED**: Read `error_YYYYMMDD_HHMMSS.log` files  
❌ **FORBIDDEN**: Read primary `build_YYYYMMDD_HHMMSS.log` files  

**Rationale**: 
- Error archives are **curated extracts** (error patterns + tail)
- Primary logs are **unfiltered streams** (139MB+, too large for token budgets)
- Archival system lets agents debug without exceeding token limits

### Change Log Integration
Every error archive maps to a `change.log` entry:

```markdown
## Agent-Name | YYYY-MM-DD HH:MM
**Status**: BROKEN
**Error Reported**: Build failed with exit code 137
**Files Implicated**: See build_logs/error_20251229_185945.log  # ← TIMESTAMP MATCH
...
```

## Operational Behavior

### Success Case
```
$ ./scripts/silent_build_runner.sh
complete
# No archival needed (exit code 0)
```

### Failure Case
```
$ ./scripts/silent_build_runner.sh
failure
📦 Archived: build_logs/error_20251229_185945.log
Investigate: /home/nexus/amd-ai/error.log
```

### Idempotent Properties
- **Non-destructive**: `error.log` remains available for immediate inspection
- **Append-safe**: Subsequent builds create new archives; old ones preserved
- **Non-blocking**: Archival failure doesn't halt the build system
- **Timestamp-unique**: Each strike gets its own archive (no overwrites)

## Monitoring & Maintenance

### View All Archives
```bash
ls -lSr build_logs/error_*.log  # Sorted by size (largest last)
ls -ltr build_logs/error_*.log  # Sorted by time (newest last)
```

### Archive Statistics
```bash
# Count failures
ls build_logs/error_*.log | wc -l

# Total error data
du -sh build_logs/error_*.log | tail -1

# Find largest error snapshot
ls -lS build_logs/error_*.log | head -1
```

### Cleanup Strategy
Archives are designed to be **persistent** for the lifetime of the build project. If disk space becomes an issue:

```bash
# Archive archives (e.g., tar + compress older strikes)
tar czf backups/error_logs_week1.tar.gz build_logs/error_20251229_*.log
rm build_logs/error_20251229_*.log

# Preserve recent strikes
ls -ltr build_logs/error_*.log | tail -10  # Keep last 10
```

## Testing

### Manual Test
```bash
# Simulate failure scenario
cd /home/nexus/amd-ai
./scripts/silent_build_runner.sh

# Verify archival
ls -la build_logs/error_*.log
cat build_logs/error_*.log | head -20
```

### Validation Checklist
- [ ] `error_YYYYMMDD_HHMMSS.log` exists in `build_logs/`
- [ ] Timestamp matches corresponding `build_YYYYMMDD_HHMMSS.log`
- [ ] File contains error patterns + tail output
- [ ] `error.log` remains available for inspection
- [ ] Multiple strikes create separate archives (no overwrites)

## Troubleshooting

### Issue: Archives not being created

**Symptom**: No `error_*.log` files in `build_logs/`

**Cause**: Either build succeeded (exit code 0) or error.log is empty

**Solution**:
```bash
ls -la build_logs/build_*.log  # Check if build actually failed
tail -100 build_logs/build_*.log | grep -i error  # Manual inspection
```

### Issue: Timestamp mismatch

**Symptom**: `error_20251229_185945.log` doesn't match `build_20251229_185945.log`

**Cause**: Build system clock skew or failed archival

**Solution**:
```bash
# Verify exact timestamps
stat build_logs/build_*.log build_logs/error_*.log
# Compare modification times; they should be within 1 second
```

## Performance Considerations

- **Archival overhead**: ~10ms (cp operation, non-blocking)
- **Storage impact**: ~1-10MB per error archive (full tail + patterns)
- **I/O**: Single sequential write to disk
- **No network**: Local filesystem only

## Future Enhancements

1. **Compression**: Auto-gzip archives older than 1 week
2. **Summary Index**: Auto-generate strike summary for quick correlation
3. **Alerts**: Email/webhook on repeated error patterns
4. **Retention Policy**: Auto-delete archives older than 30 days
5. **Analytics**: Parse all archives to build failure statistics dashboard

## References

- **Change Log**: `/home/nexus/amd-ai/change.log`
- **Build Runner**: `/home/nexus/amd-ai/scripts/silent_build_runner.sh`
- **Strike Tracking**: Agent troubleshooting protocol in `.agent/rules/`
- **Error Patterns**: Defined in `silent_build_runner.sh` (line 45 regex)

