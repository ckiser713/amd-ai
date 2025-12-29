#!/bin/bash
#
# verify-open-notebook.sh: Verify notebook/model loading with graceful error handling
#
# This script tests model loading without crashing on benign pipe errors or failed requests.
# It handles:
# - SIGPIPE errors gracefully (broken client connections)
# - HTTP 404s from missing models
# - Timeout/network issues with retry logic
#

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="${1:-.}"
TIMEOUT=${TIMEOUT:-30}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-2}
LOG_FILE="${LOG_FILE:-./verify-notebook.log}"

# Trap SIGPIPE to avoid aborting on broken pipes
trap 'true' PIPE

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

warn() {
    echo "[WARN] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "[ERROR] $*" | tee -a "$LOG_FILE"
    return 1
}

info() {
    echo "[INFO] $*" | tee -a "$LOG_FILE"
}

# Verify that notebooks/models exist without crashing
verify_notebooks() {
    local count=0
    local failed=0
    
    info "Scanning models directory: $MODELS_DIR"
    
    if [[ ! -d "$MODELS_DIR" ]]; then
        error "Models directory not found: $MODELS_DIR"
        return 1
    fi
    
    # Find all .gguf model files
    while IFS= read -r model_file; do
        ((count++))
        local model_name=$(basename "$model_file" .gguf)
        
        info "Verifying model: $model_name ($model_file)"
        
        # Check file validity
        if [[ ! -r "$model_file" ]]; then
            warn "Model file not readable: $model_file"
            ((failed++))
            continue
        fi
        
        # Basic GGUF magic check (first 4 bytes should be "GGUF")
        local magic=$(od -A n -N 4 -t x1 "$model_file" 2>/dev/null | tr -d ' ')
        if [[ "$magic" != "47474 6" && "$magic" != "47474" ]]; then
            warn "Model file is not a valid GGUF file: $model_file"
            ((failed++))
            continue
        fi
        
        info "✓ Model verified: $model_name"
    done < <(find "$MODELS_DIR" -name "*.gguf" -type f)
    
    if [[ $count -eq 0 ]]; then
        warn "No GGUF models found in $MODELS_DIR"
        return 0  # Not an error if no models exist
    fi
    
    info "Scanned $count models, $failed failed"
    
    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Verify HTTP connectivity to a server without crashing on pipe errors
verify_server_connectivity() {
    local host="${1:-localhost}"
    local port="${2:-8080}"
    local retry=0
    
    info "Verifying connectivity to $host:$port"
    
    while [[ $retry -lt $MAX_RETRIES ]]; do
        # Use timeout to avoid hanging, suppress SIGPIPE errors
        if timeout "$TIMEOUT" curl -s -f "http://$host:$port/props" >/dev/null 2>&1; then
            info "✓ Server connectivity verified"
            return 0
        fi
        
        local exit_code=$?
        
        # SIGPIPE (141) is benign, retry; other failures might indicate real problems
        if [[ $exit_code -eq 141 ]]; then
            warn "SIGPIPE error (benign), retrying..."
        elif [[ $exit_code -eq 124 ]]; then
            warn "Request timeout, retrying..."
        elif [[ $exit_code -eq 7 ]]; then
            warn "Failed to connect to $host:$port, retrying..."
        else
            error "Failed to verify connectivity: exit code $exit_code"
        fi
        
        ((retry++))
        if [[ $retry -lt $MAX_RETRIES ]]; then
            sleep "$RETRY_DELAY"
        fi
    done
    
    error "Failed to verify server connectivity after $MAX_RETRIES attempts"
    return 1
}

main() {
    log "Starting notebook/model verification"
    
    verify_notebooks || {
        warn "Some notebooks failed verification, but continuing..."
    }
    
    # Only verify server if we have parameters
    if [[ $# -gt 0 ]]; then
        verify_server_connectivity "$@" || true
    fi
    
    info "Verification complete"
}

main "$@"
