import os
import glob
import sys

def patch_xformers_headers():
    # Use XFORMERS_SRC env var or default to current directory
    src_dir = os.environ.get("XFORMERS_SRC", os.getcwd())
    print(f"🔍 Scanning {src_dir} for xFormers headers to patch...")

    # Pattern to search for
    # We are looking for headers (likely .hpp, .h, .cuh) in ck_tile or similar paths
    # The user specifically mentioned ck_tile headers.
    patterns = [
        os.path.join(src_dir, "**", "*.hpp"),
        os.path.join(src_dir, "**", "*.h"),
        os.path.join(src_dir, "**", "*.cuh"),
    ]

    files_to_patch = []
    for pattern in patterns:
        files_to_patch.extend(glob.glob(pattern, recursive=True))

    patched_count = 0
    target_string = "LDS_READ_FREQ = 64"
    replacement_string = "LDS_READ_FREQ = 32"

    for file_path in files_to_patch:
        try:
            with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()

            if target_string in content:
                print(f"🔧 Patching {file_path}...")
                new_content = content.replace(target_string, replacement_string)
                
                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(new_content)
                
                patched_count += 1
        except Exception as e:
            print(f"⚠️ Failed to process {file_path}: {e}")

    if patched_count > 0:
        print(f"✅ Successfully patched {patched_count} files for Wave32.")
    else:
        print("ℹ️ No files needed patching (or target string not found).")

if __name__ == "__main__":
    patch_xformers_headers()
