---
description: Execute the silent build runner and troubleshoot failures using only error.log with a 3-strike confidence protocol.
---

# /execute_silent Workflow

This command executes the silent build runner in a fully autonomous repair loop with a 3-strike confidence protocol.

## Protocol Overview

### Strike Tracking
- **Strike 1**: Auto-fix based on `error.log` and rerun immediately
- **Strike 2**: Auto-fix based on `error.log` and rerun immediately  
- **Strike 3**: Confidence check for 4th attempt
  - If confidence ≥ 85%: Apply fix #4 and rerun
  - If confidence < 85%: HALT and provide handoff to superior model

### Autonomous Operation
For strikes 1-2, I will:
1. Read ONLY `error.log` (never the full build logs)
2. Identify the root cause
3. Apply the fix immediately
4. Rerun `./scripts/silent_build_runner.sh`
5. Track the strike count

### Confidence Assessment (Strike 3 Only)
After the 3rd consecutive failure, before attempting fix #4:
1. Evaluate: "Am I ≥85% confident this fix will work?"
2. If YES: Apply fix #4 and rerun
3. If NO: Generate handoff artifact and recommend **Gemini 1.5 Pro (High)** or **Claude 3.5 Opus**

// turbo-all
## Execution Steps
1. Initialize strike counter (start at 0)
2. Run `./scripts/silent_build_runner.sh`
3. On `complete`: Report success and exit
4. On `failure`:
   - Increment strike counter
   - Read `error.log` exclusively
   - If strike ≤ 2: Fix immediately and loop to step 2
   - If strike = 3: Perform confidence check
     - ≥85%: Fix and loop to step 2
     - <85%: Generate handoff and HALT
