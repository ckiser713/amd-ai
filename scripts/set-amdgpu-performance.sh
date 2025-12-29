#!/bin/sh
set -e
logger -t amdgpu-perf "Setting AMD GPU performance mode"

write_with_retry() {
  file="$1"
  value="$2"
  max=6
  i=1
  while [ "$i" -le "$max" ]; do
    if printf '%s' "$value" > "$file" 2>/dev/null; then
      logger -t amdgpu-perf "Wrote $value to $file (attempt $i)"
      return 0
    fi
    logger -t amdgpu-perf "Failed to write $file (attempt $i), retrying"
    sleep "$i"
    i=$((i + 1))
  done
  logger -t amdgpu-perf "Giving up writing $file after $max attempts"
  return 1
}

if command -v rocm-smi >/dev/null 2>&1; then
  rocm-smi --setperflevel high >/dev/null 2>&1 || true
fi

for dev in /sys/class/drm/card*/device; do
  [ -d "$dev" ] || continue
  pd="$dev/power_dpm_force_performance_level"
  pp="$dev/pp_power_profile_mode"
  [ -e "$pd" ] && write_with_retry "$pd" performance || true
  [ -e "$pp" ] && write_with_retry "$pp" high || true
done

logger -t amdgpu-perf "AMD GPU performance mode applied"
