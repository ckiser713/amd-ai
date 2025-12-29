#!/usr/bin/env python3
"""
xformers ck_tile Wave32 Division-by-Zero Fix
Applies safe division guards to prevent compile errors on gfx1151/Wave32.
ALWAYS attempts to apply the fix (removes flawed idempotency checks).

Usage: 
  python3 apply_xformers_fix.py              # Uses default relative path
  XFORMERS_SRC=/path/to/xformers python3 apply_xformers_fix.py  # Custom path
"""

import os
import sys
import re

# Allow override via environment variable for container builds
XFORMERS_SRC = os.environ.get("XFORMERS_SRC", "src/extras/xformers")
RELATIVE_PATH = "third_party/composable_kernel_tiled/include/ck_tile/ops/fmha/pipeline/block_fmha_bwd_pipeline_default_policy_hip.hpp"
TARGET_FILE = os.path.join(XFORMERS_SRC, RELATIVE_PATH)

def main():
    # Path resolution with fallbacks
    target = None
    for path in [
        TARGET_FILE,
        RELATIVE_PATH,  # Maybe already in xformers dir
        os.path.join("/app/src/extras/xformers", RELATIVE_PATH),  # Docker container
        os.path.join("/app", RELATIVE_PATH),  # Alternative Docker layout
    ]:
        if os.path.exists(path):
            target = path
            break
    
    if target is None:
        print(f"Error: Could not find target file in any known path!")
        print(f"  Tried: {TARGET_FILE}")
        return 1
    
    print(f"Patching {target}...")
    
    with open(target, "r") as f:
        content = f.read()
    
    original_content = content
    changes_made = []
    
    # ==========================================================================
    # PATTERN 1: LDS_READ_INST / (MFMA_INST - MFMA_INST_LDS_WRITE)
    # ==========================================================================
    old_block = """            constexpr index_t LDS_READ_PER_MFMA =
                (MFMA_INST - MFMA_INST_LDS_WRITE) > 0
                    ? LDS_READ_INST / (MFMA_INST - MFMA_INST_LDS_WRITE) > 0
                          ? LDS_READ_INST / (MFMA_INST - MFMA_INST_LDS_WRITE)
                          : 1
                    : 0;"""
    
    new_block = """            // Wave32 safe: guard against division by zero
            constexpr index_t DENOM_SAFE = (MFMA_INST - MFMA_INST_LDS_WRITE) > 0 
                                            ? (MFMA_INST - MFMA_INST_LDS_WRITE) : 1;
            constexpr index_t LDS_READ_PER_MFMA =
                (MFMA_INST - MFMA_INST_LDS_WRITE) > 0
                    ? LDS_READ_INST / DENOM_SAFE > 0
                          ? LDS_READ_INST / DENOM_SAFE
                          : 1
                    : 0;"""
    
    if old_block in content:
        content = content.replace(old_block, new_block)
        changes_made.append("LDS_READ_PER_MFMA division (Pattern 1)")
    
    # ==========================================================================
    # PATTERN 2: KThreadRead / (kfold * K0PerThreadWrite / K0PerThreadRead)
    # ==========================================================================
    old_KThreadRead = """        constexpr auto KThreadReadPerm =
            (kfold * K0PerThreadWrite / K0PerThreadRead) > 1
                ? KThreadRead / (kfold * K0PerThreadWrite / K0PerThreadRead)
                : KThreadRead;"""
    
    new_KThreadRead = """        // Wave32 safe: guard KThreadReadPerm division
        constexpr auto KFoldDenom = (kfold * K0PerThreadWrite / K0PerThreadRead);
        constexpr auto KFoldDenomSafe = KFoldDenom > 0 ? KFoldDenom : 1;
        constexpr auto KThreadReadPerm =
            KFoldDenom > 1
                ? KThreadRead / KFoldDenomSafe
                : KThreadRead;"""
    
    if old_KThreadRead in content:
        content = content.replace(old_KThreadRead, new_KThreadRead)
        changes_made.append("KThreadReadPerm division (Pattern 2)")
    
    # ==========================================================================
    # PATTERN 3: KThreadRead = get_warp_size() / MNPerXDL
    # ==========================================================================
    old_p3 = "constexpr auto KThreadRead      = get_warp_size() / MNPerXDL;"
    new_p3 = "constexpr auto KThreadRead      = (MNPerXDL > 0) ? get_warp_size() / MNPerXDL : 1;"
    if old_p3 in content:
        content = content.replace(old_p3, new_p3)
        changes_made.append("KThreadRead safe division (Pattern 3)")
    
    # ==========================================================================
    # PATTERN 4: K0PerThreadRead = K0Number / KThreadRead
    # ==========================================================================
    old_p4 = "constexpr auto K0PerThreadRead  = K0Number / KThreadRead;"
    new_p4 = "constexpr auto K0PerThreadRead  = (KThreadRead > 0) ? K0Number / KThreadRead : 1;"
    if old_p4 in content:
        content = content.replace(old_p4, new_p4)
        changes_made.append("K0PerThreadRead safe division (Pattern 4)")
    
    # Write if changed
    if changes_made:
        with open(target, "w") as f:
            f.write(content)
        for change in changes_made:
            print(f"  ✓ Fixed {change}")
        print("Patch applied successfully.")
    else:
        # Check if already patched
        if "DENOM_SAFE" in content and "KFoldDenomSafe" in content:
            print("  ✓ All patterns already patched (verified)")
        else:
            print("  ⚠ No patterns matched - file structure may differ")
            # Fall back to regex replacement for safety
            regex_changes = 0
            
            # Regex pattern for any unguarded division by (MFMA_INST - MFMA_INST_LDS_WRITE)
            pattern = r'LDS_READ_INST / \(MFMA_INST - MFMA_INST_LDS_WRITE\)'
            replacement = r'LDS_READ_INST / ((MFMA_INST - MFMA_INST_LDS_WRITE) > 0 ? (MFMA_INST - MFMA_INST_LDS_WRITE) : 1)'
            new_content, n = re.subn(pattern, replacement, content)
            if n > 0:
                print(f"  ✓ Regex fixed {n} LDS_READ_INST divisions")
                content = new_content
                regex_changes += n
            
            if regex_changes > 0:
                with open(target, "w") as f:
                    f.write(content)
                print("Regex fallback patch applied.")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
