#!/usr/bin/env bash
# Simple smoke test: run llama-server (router) under a short timeout and check it doesn't SIGSEGV.
# Assumes `llama-server` is on PATH or adjust BINARY variable.

set -eu
BINARY=${1:-./llama-server}
TIMEOUT=${2:-8} # seconds

if [ ! -x "$BINARY" ]; then
  echo "binary $BINARY not found or not executable"
  exit 2
fi

ulimit -c unlimited || true

# Run in background and wait shortly
"$BINARY" --router --port 18080 &
PID=$!

sleep $TIMEOUT

if kill -0 $PID 2>/dev/null; then
  echo "process $PID still alive after ${TIMEOUT}s — likely OK"
  kill $PID
  wait $PID || true
  exit 0
else
  echo "process $PID exited early — check for crash or core dump"
  exit 1
fi
