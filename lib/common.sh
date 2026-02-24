#!/usr/bin/env bash
# lib/common.sh - Shared functions for PVE B2 Age Backup
# This file is sourced by other scripts

# Ensure this file is sourced, not executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This file should be sourced, not executed directly" >&2
    exit 1
fi

# Timestamp function for logging
ts() { 
    date -Is 
}

# Logging function - usage: log "message"
# Requires LOG variable to be set before sourcing
log() { 
    : "${LOG:?LOG variable must be set}"
    echo "$(ts) $*" | tee -a "$LOG"
}

# Check if a command exists - usage: need command_name
need() { 
    command -v "$1" >/dev/null 2>&1 || { 
        log "ERROR: Missing required binary: $1"
        exit 1
    }
}

# Sanitize paths to remove double slashes
sanitize_path() {
    local path="$1"
    while [[ "$path" == *"//"* ]]; do
        path="${path//\/\//\/}"
    done
    printf '%s\n' "$path"
}

# Retry a command with exponential backoff
# Usage: retry_with_backoff "command" max_attempts base_delay
retry_with_backoff() {
    local cmd="$1"
    local max_attempts="${2:-6}"
    local base_delay="${3:-20}"
    local attempt=1
    
    while true; do
        log "Attempt $attempt/$max_attempts: ${cmd:0:80}..."
        
        # We use 'bash -c' here because the command might be a complex string with pipes
        # and we want it to run in its own shell environment.
        if bash -c "set -o pipefail; $cmd" >>"${LOG:-/dev/null}" 2>&1; then
            return 0
        fi
        
        if (( attempt >= max_attempts )); then
            log "ERROR: All $max_attempts attempts failed"
            return 1
        fi
        
        local delay=$(( base_delay * (2 ** (attempt - 1)) ))
        log "Failed, waiting ${delay}s before retry..."
        sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
}

retry_with_backoff_fn() {
    local fn="$1"
    local max_attempts="${2:-6}"
    local base_delay="${3:-20}"
    local attempt=1
    shift 3

    if ! declare -F "$fn" >/dev/null 2>&1; then
        log "ERROR: Retry target is not a function: $fn"
        return 1
    fi

    while true; do
        log "Attempt $attempt/$max_attempts: $fn"

        if "$fn" "$@" >>"${LOG:-/dev/null}" 2>&1; then
            return 0
        fi

        if (( attempt >= max_attempts )); then
            log "ERROR: All $max_attempts attempts failed for $fn"
            return 1
        fi

        local delay=$(( base_delay * (2 ** (attempt - 1)) ))
        log "Failed, waiting ${delay}s before retry..."
        sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
}

# Validate configuration file exists and is readable
# Usage: load_config [config_path]
load_config() {
    local config_file="${1:-${CONFIG_FILE:-/etc/pve-b2-age-backup/config.env}}"
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file not found: $config_file" >&2
        return 1
    fi
    
    if [[ ! -r "$config_file" ]]; then
        echo "ERROR: Configuration file not readable: $config_file" >&2
        return 1
    fi
    
    # shellcheck source=/dev/null
    if ! source "$config_file"; then
        echo "ERROR: Failed to parse configuration file: $config_file" >&2
        return 1
    fi
}

# Validate required configuration variables
# Usage: validate_config "VAR1" "VAR2" ...
validate_config() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required configuration: ${missing[*]}" >&2
        return 1
    fi
}
