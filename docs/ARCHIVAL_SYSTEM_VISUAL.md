# Error Log Archival System — Visual Architecture

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    Build Execution                              │
│        ./scripts/80_run_complete_build_docker.sh                │
└────────────────┬────────────────────────────────────────────────┘
                 │
                 ▼ (STDOUT/STDERR redirected)
        ┌────────────────────────┐
        │  build_20251229_185215 │
        │        .log            │  139MB full build output
        │  (comprehensive)       │  All stdout/stderr/diagnostics
        └────────┬───────────────┘
                 │
         Exit Code: 0 OR ≠ 0
         (captured by silent_build_runner.sh)
                 │
        ┌────────┴────────────────┐
        │                         │
   ┌────▼────────────────┐  ┌────▼─────────────────────┐
   │   EXIT CODE = 0     │  │   EXIT CODE ≠ 0         │
   │   SUCCESS CASE      │  │   FAILURE CASE          │
   └──────────────────────  └────┬────────────────────┘
                                 │
                    ┌────────────▼──────────────┐
                    │  Error Pattern Extraction │
                    │  • Grep for error keywords│
                    │  • Extract tail -n 50     │
                    │  • Format into error.log  │
                    └────────────┬──────────────┘
                                 │
        ┌────────────────────────▼────────────────────────┐
        │  error.log (temporary, active file)            │
        │  • Error patterns (up to 20 lines)             │
        │  • Tail 50 (context)                           │
        │  • Exit code                                   │
        │  • Overwritten on next failure                 │
        └────────────────────────┬────────────────────────┘
                                 │
        ┌────────────────────────▼────────────────────────┐
        │  ARCHIVAL STEP (NEW)                           │
        │  • Extract timestamp from build_*.log          │
        │    Result: 20251229_185215                     │
        │  • Create archive filename                     │
        │    Result: error_20251229_185215.log           │
        │  • Copy error.log → archive                    │
        │  • Preserve for historical analysis            │
        └────────────────────────┬────────────────────────┘
                                 │
        ┌────────────────────────▼────────────────────────┐
        │  build_logs/error_20251229_185215.log          │
        │  (PERMANENT ARCHIVE)                           │
        │  • Never overwritten                           │
        │  • 1:1 mapping with build_*.log               │
        │  • Available for agent inspection              │
        │  • Enables Strike Tracking                    │
        └────────────────────────────────────────────────┘
```

## Strike Timeline Visualization

```
Time ──────────────────────────────────────────────────────────────►

Strike 1
├─ Build: 18:52:15 (build_20251229_185215.log)
├─ Error: Exit 137 (OOM)
├─ Archive: error_20251229_185215.log ✅
└─ Agent Action: Reduce MAX_JOBS

Strike 2
├─ Build: 18:55:30 (build_20251229_185530.log)
├─ Error: Exit 137 (Still OOM)
├─ Archive: error_20251229_185530.log ✅
└─ Agent Action: Enable LLD linker

Strike 3
├─ Build: 18:59:45 (build_20251229_185945.log)
├─ Error: Exit 1 (Compilation error)
├─ Archive: error_20251229_185945.log ✅
└─ Agent Action: Patch xformers ck_tile

Strike 4
├─ Build: 19:02:01 (build_20251229_190201.log)
├─ Error: Exit 128 (Git lock)
├─ Archive: error_20251229_190201.log ✅
└─ Agent Action: Clean git locks

Strike 5
├─ Build: 19:04:45 (build_20251229_190445.log)
├─ Error: Exit 0 (SUCCESS!) ✅
└─ No archival needed (success case)

Result: 4 archived errors show progression from OOM → compilation → system issues → SUCCESS
```

## File Structure

```
/home/nexus/amd-ai/
│
├── error.log ◄─ Active/temporary (overwritten each failure)
│              └─ Agent inspects this for immediate debugging
│
├── build_logs/
│   ├── build_20251229_185215.log ◄─ Strike 1 full output (139MB)
│   ├── error_20251229_185215.log ◄─ Strike 1 archive (5-20MB)
│   │                               ├─ === FAIL: 20251229_185215 ===
│   │                               ├─ Code: 137
│   │                               ├─ Patterns: OOM, xformers
│   │                               └─ Tail 50 (last 50 lines)
│   │
│   ├── build_20251229_185530.log ◄─ Strike 2 full output (139MB)
│   ├── error_20251229_185530.log ◄─ Strike 2 archive (5-20MB)
│   │
│   ├── build_20251229_185945.log ◄─ Strike 3 full output (139MB)
│   ├── error_20251229_185945.log ◄─ Strike 3 archive (5-20MB)
│   │
│   └── [more build_*.log and error_*.log pairs]
│
├── change.log
│   ├── ## [Agent-Required] | 2025-12-29 18:52
│   │   Files Implicated: See error.log ◄─ Points to active error.log
│   │
│   └── ## Agent-Fixes | 2025-12-29 18:55
│       Files Implicated: error_20251229_185215.log ◄─ Points to archive
│
└── scripts/
    └── silent_build_runner.sh
        ├── Lines 30-32: Build execution
        ├── Lines 34-48: Error pattern extraction → error.log
        ├── Lines 50-61: ✨ Archival logic (NEW)
        │   ├── Extract timestamp from build_*.log
        │   ├── Create error_TIMESTAMP.log
        │   └── Copy to build_logs/ directory
        └── Lines 52-78: Change.log template
```

## Key Insight: 1:1 Timestamp Mapping

```
Build Filename:   build_20251229_185215.log
                         │
                  Extract YYYYMMDD_HHMMSS
                         │
                         ▼
                   20251229_185215
                         │
                  Build archive name
                         ▼
Archive Filename: error_20251229_185215.log

✅ PERFECT 1:1 MAPPING
   build_* ↔ error_* (same timestamp)
   Enables instant correlation
```

## Comparison: Before vs After

### BEFORE (Single error.log)
```
Build Failures:     Strike 1    Strike 2    Strike 3
error.log content:  Error-1  →  Error-2  →  Error-3
                    (lost!)     (lost!)     (lost!)

Problem: Only current error visible, history lost
Result: Agents can't trace fix progression
```

### AFTER (With Archival)
```
Build Failures:     Strike 1          Strike 2          Strike 3
error.log content:  Error-1       →   Error-2       →   Error-3
Archives:           error_...1.log     error_...2.log     error_...3.log
                    (preserved)        (preserved)        (preserved)

Solution: All errors archived with timestamps
Result: Complete history enables root cause identification
```

## Agent Workflow Integration

```
┌─────────────────────────────────────────────────┐
│          AGENT WORKFLOW (Simplified)            │
└──────────────────────┬──────────────────────────┘
                       │
     ┌─────────────────▼──────────────────┐
     │  1. SILENT RUNNER EXECUTES         │
     │  ./scripts/silent_build_runner.sh  │
     └─────────────────┬──────────────────┘
                       │
     ┌─────────────────▼──────────────────┐
     │  2. BUILD FAILS (exit ≠ 0)         │
     │  Archival triggered automatically  │
     └─────────────────┬──────────────────┘
                       │
     ┌─────────────────▼──────────────────┐
     │  3. ERROR ARCHIVE CREATED          │
     │  error_YYYYMMDD_HHMMSS.log         │
     └─────────────────┬──────────────────┘
                       │
     ┌─────────────────▼──────────────────┐
     │  4. AGENT INSPECTION               │
     │  cat error.log (immediate)         │
     │  cat error_*.log (historical)      │
     │  diff errors (compare strikes)     │
     └─────────────────┬──────────────────┘
                       │
     ┌─────────────────▼──────────────────┐
     │  5. AGENT ANALYSIS                 │
     │  Update change.log with findings   │
     │  Identify root cause               │
     │  Plan fix                          │
     └─────────────────┬──────────────────┘
                       │
     ┌─────────────────▼──────────────────┐
     │  6. IMPLEMENT FIX                  │
     │  Modify affected scripts/files     │
     │  Test locally if possible          │
     └─────────────────┬──────────────────┘
                       │
     ┌─────────────────▼──────────────────┐
     │  7. RETRY BUILD                    │
     │  ./scripts/silent_build_runner.sh  │
     │  (Loop back to step 2)             │
     └─────────────────┬──────────────────┘
                       │
     ┌─────────────────▼──────────────────┐
     │  8. ON SUCCESS                     │
     │  Documentation complete            │
     │  Artifacts ready                   │
     │  Mission accomplished              │
     └─────────────────────────────────────┘
```

## Strike Counting Logic

```bash
# How to know what strike we're on?
CURRENT_STRIKE=$(ls -1 build_logs/error_*.log 2>/dev/null | wc -l)
echo "Current strike: $CURRENT_STRIKE"

# Example with 4 archived errors
build_logs/error_20251229_185215.log  (1)
build_logs/error_20251229_185530.log  (2)
build_logs/error_20251229_185945.log  (3)
build_logs/error_20251229_190201.log  (4)
                                      ↑
                              Total = 4 strikes

# Next run will be Strike 5
NEXT_STRIKE=$((CURRENT_STRIKE + 1))
```

## Performance Profile

```
Operation                    Time        Disk Space
─────────────────────────────────────────────────────
Build execution              ~2-8 hours  Variable
Build log generation         Auto        ~139MB per strike
Error pattern extraction     <1 sec      Auto (in error.log)
Archival (cp operation)      ~10ms       ~5-20MB per archive

Total overhead:              ~10ms       ~5-20MB per failure
(negligible vs 2-8 hour build)
```

## Summary

✅ **Archival system**:
- Automatic (no manual steps)
- Synchronized (timestamp matching)
- Efficient (10ms overhead, token-aware)
- Non-destructive (preserves history)
- Enables Strike Tracking

✅ **Result**:
- Complete error history preserved
- Root causes visible across multiple strikes
- Agents can debug without reading primary logs
- Protocol compliant

