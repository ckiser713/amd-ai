# Error Log Archival System — Quick Reference Card

## TL;DR

✅ **What**: Automatic error.log archival with build log timestamp synchronization  
✅ **Where**: `scripts/silent_build_runner.sh` (lines 50-61)  
✅ **When**: Every build failure (exit code ≠ 0)  
✅ **Why**: Strike Tracking, protocol compliance, historical debugging  
✅ **Result**: `error_YYYYMMDD_HHMMSS.log` in `build_logs/`

## One-Liner Usage

```bash
# View all strikes (errors) in order
ls -ltr build_logs/error_*.log

# Read most recent strike
tail -1 build_logs/error_*.log | xargs cat

# Find OOM failures
grep "Code: 137" build_logs/error_*.log | cut -d: -f1

# Compare Strike 2 vs Strike 5
diff build_logs/error_20251229_185530.log build_logs/error_20251229_190445.log

# Count total strikes
ls build_logs/error_*.log | wc -l
```

## File Quick Map

| File | Purpose | Size | Overwritten? |
|------|---------|------|-------------|
| `error.log` | Active temp file | 5-20MB | ✅ Yes (each failure) |
| `build_logs/build_TIMESTAMP.log` | Full build output | ~139MB | ❌ No (permanent) |
| `build_logs/error_TIMESTAMP.log` | Error archive | 5-20MB | ❌ No (permanent) |

## Exit Code Quick Reference

| Code | Meaning | Common Cause |
|------|---------|-------------|
| 0 | Success ✅ | N/A |
| 1 | Generic error | Compilation, config, logic |
| 128 | Signal termination | Git lock, process killed |
| 137 | OOM (killed) | Parallelism too aggressive |

## Timestamp Format

```
YYYYMMDD_HHMMSS
│      │ │ │ │ │
│      │ │ │ └─ Seconds
│      │ │ └─── Minutes
│      │ └───── Hours (24-hour)
│      └─────── Month-Day
└────────────── Year

Example: 20251229_185215
         2025-12-29 18:52:15
```

## Archive Naming Pattern

```
build_YYYYMMDD_HHMMSS.log  ←─┐
                               ├─ SAME TIMESTAMP
error_YYYYMMDD_HHMMSS.log  ←─┘
```

## Key Commands

### View Latest Strike
```bash
cat build_logs/error_*.log | tail -1 | xargs cat
```

### View All Strikes Timeline
```bash
for f in $(ls -tr build_logs/error_*.log); do
    echo "$(basename "$f"): $(grep 'Code:' "$f" | head -1)"
done
```

### Find Specific Error Type
```bash
# xformers errors
grep -l "xformers" build_logs/error_*.log

# Memory errors
grep -l "memory\|OOM" build_logs/error_*.log

# Compilation errors
grep -l "error:" build_logs/error_*.log
```

### Compare Two Strikes
```bash
# Show differences
diff error_strike2.log error_strike5.log

# Show only patterns section
grep "DETECTED ERROR PATTERNS" -A 20 error_strike2.log
grep "DETECTED ERROR PATTERNS" -A 20 error_strike5.log
```

### Statistical Analysis
```bash
# Most common exit codes
grep "Code:" build_logs/error_*.log | cut -d' ' -f2 | sort | uniq -c | sort -rn

# Error archive sizes (proxy for complexity)
ls -lhS build_logs/error_*.log | awk '{print $5 "\t" $9}'

# Total archived data
du -sh build_logs/error_*.log
```

## Archival Logic (In Code)

```bash
# Extract timestamp
ARCHIVE_TIMESTAMP=$(basename "$FULL_LOG" | sed 's/^build_//; s/\.log$//')

# Create archive path
ARCHIVED_ERROR="$LOG_DIR/error_${ARCHIVE_TIMESTAMP}.log"

# Copy if non-empty
if [[ -s "$ERROR_LOG" ]]; then
    cp "$ERROR_LOG" "$ARCHIVED_ERROR"
fi
```

## Integration Points

### In change.log
```markdown
**Files Implicated**: build_logs/error_YYYYMMDD_HHMMSS.log
```

### In Strike Tracking
```bash
STRIKE_NUMBER=$(ls -1 build_logs/error_*.log | wc -l)
LATEST_STRIKE=$(ls -1t build_logs/error_*.log | head -1)
```

### In Agent Workflow
```bash
# Identify current work
cat error.log                    # Immediate inspection
cat build_logs/error_*.log      # Historical context
diff error_*.log                # Track fix progress
```

## Troubleshooting

### "Archives not being created"
```bash
# Check if build is actually failing
tail -100 build_logs/build_*.log | grep -i error

# Check if error.log is being populated
ls -la error.log
wc -l error.log
```

### "Lost track of which strike"
```bash
# Count current strike
ls -1 build_logs/error_*.log | wc -l

# Show most recent
ls -1t build_logs/error_*.log | head -1
```

### "Need to correlate specific build"
```bash
# Find build for a specific error archive
ERROR_FILE="error_20251229_185945.log"
TIMESTAMP=$(echo "$ERROR_FILE" | sed 's/error_//; s/\.log//')
BUILD_FILE="build_${TIMESTAMP}.log"

ls -la "build_logs/${BUILD_FILE}"
```

## Performance Expectations

| Operation | Time | Notes |
|-----------|------|-------|
| Archival overhead | ~10ms | Single cp, negligible |
| Storage per archive | 5-20MB | Depends on error verbosity |
| Search/grep | <1 sec | Across all archives |
| Diff two archives | <1 sec | Standard diff operation |

## Operational Checklist

- [ ] Run `./scripts/silent_build_runner.sh`
- [ ] On failure: check `ls build_logs/error_*.log`
- [ ] Verify timestamp matches: `ls build_logs/build_*.log | head -1`
- [ ] Inspect latest error: `cat build_logs/error_*.log | tail -1 | xargs cat`
- [ ] Compare with previous: `diff error_*.log | head -20`
- [ ] Update change.log with findings
- [ ] Apply fix
- [ ] Retry build
- [ ] Repeat until "complete"

## Documentation References

- **Full Guide**: `docs/ERROR_LOG_ARCHIVAL.md`
- **Operator Guide**: `docs/STRIKE_TRACKING.md`
- **Visual Diagrams**: `docs/ARCHIVAL_SYSTEM_VISUAL.md`
- **Implementation**: `scripts/silent_build_runner.sh` (lines 50-61)
- **Change Log**: `change.log`

## Key Takeaways

✅ **Automatic**: No manual steps required  
✅ **Synchronized**: 1:1 timestamp mapping  
✅ **Efficient**: 10ms overhead, token-aware  
✅ **Traceable**: Complete strike history  
✅ **Protocol-Compliant**: Supports /execute_silent rules  

## Example: Full Strike Tracking Session

```bash
# 1. View all strikes
$ ls -ltr build_logs/error_*.log

# 2. Count strikes
$ ls build_logs/error_*.log | wc -l
5

# 3. Check progression
$ for f in $(ls build_logs/error_*.log); do grep Code: "$f"; done
Code: 137      # Strike 1 - OOM
Code: 137      # Strike 2 - Still OOM
Code: 1        # Strike 3 - New error
Code: 128      # Strike 4 - Git issue
Code: 0 (SUCCESS!)  # Strike 5 - Fixed!

# 4. Document success
$ cat change.log | tail -20
## Agent-Final | 2025-12-29 19:05
Status: SUCCESS
Strikes: 5
Root Causes Fixed: Parallelism, git locks, compilation
Recommendation: Deploy artifacts
```

## Contact & Escalation

If you encounter:
- **Repeated same error** → Check pattern matching in error extraction
- **Archives not created** → Verify error.log being populated
- **Timestamp mismatches** → Check sed pattern in archival logic
- **Out of space** → Compress old archives (tar + gzip)

See: `docs/ERROR_LOG_ARCHIVAL.md` → Troubleshooting section

