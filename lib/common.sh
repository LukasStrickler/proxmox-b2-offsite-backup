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
    echo "$1" | sed 's#//*#/#g'
}

# Validate that a path contains only safe characters (no shell metacharacters)
# Usage: validate_path_safe "/path/to/file"
validate_path_safe() {
    local path="$1"
    local name="${2:-path}"
    # Allow: alphanumeric, underscore, hyphen, dot, forward slash, space
    # Block: backticks, dollar signs, semicolons, pipes, quotes, etc.
    if [[ ! "$path" =~ ^[a-zA-Z0-9_./\ -]+$ ]]; then
        log "ERROR: Invalid $name (contains unsafe characters): $path"
        return 1
    fi
    return 0
}

# Retry a function with exponential backoff
# Usage: retry_with_backoff_func max_attempts base_delay function_name [args...]
# The function must return 0 on success, non-zero on failure
retry_with_backoff_func() {
    local max_attempts="${1:-6}"
    local base_delay="${2:-20}"
    shift 2
    local func_name="$1"
    shift
    
    local attempt=1
    
    while true; do
        log "Attempt $attempt/$max_attempts: $func_name"
        
        if "$func_name" "$@"; then
            return 0
        fi
        
        if (( attempt >= max_attempts )); then
            log "ERROR: All $max_attempts attempts failed for $func_name"
            return 1
        fi
        
        local delay=$(( base_delay * (2 ** (attempt - 1)) ))
        log "Failed, waiting ${delay}s before retry..."
        sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
}

# Check if there is sufficient disk space in a directory
# Usage: check_disk_space required_bytes target_dir
check_disk_space() {
    local required_bytes="$1"
    local target_dir="$2"
    
    if [[ ! -d "$target_dir" ]]; then
        log "ERROR: Target directory does not exist: $target_dir"
        return 1
    fi
    
    if [[ ! "$required_bytes" =~ ^[0-9]+$ ]] || (( required_bytes < 0 )); then
        log "ERROR: Invalid required_bytes value: $required_bytes"
        return 1
    fi
    
    if (( required_bytes > 9007199254740991 )); then
        log "ERROR: required_bytes value too large (would overflow): $required_bytes"
        return 1
    fi
    
    local available_kb
    available_kb=$(df -kP "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}')
    
    if [[ -z "$available_kb" ]]; then
        log "ERROR: Could not determine available space for: $target_dir"
        return 1
    fi
    
    local available_bytes=$((available_kb * 1024))
    
    if (( available_bytes < required_bytes )); then
        local needed_human needed_human=$(numfmt --to=iec-i --suffix=B "$required_bytes" 2>/dev/null || echo "${required_bytes}B")
        local avail_human avail_human=$(numfmt --to=iec-i --suffix=B "$available_bytes" 2>/dev/null || echo "${available_bytes}B")
        log "ERROR: Insufficient disk space. Need: $needed_human, Available: $avail_human"
        return 1
    fi
    
    return 0
}

# Format bytes to human readable
# Usage: format_bytes bytes
format_bytes() {
    local bytes="${1:-0}"
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
}

# Validate configuration file exists, is readable, and has correct ownership
# Uses hardcoded path: /etc/pve-b2-age-backup/config.env
# Usage: load_config
load_config() {
    local config_file="/etc/pve-b2-age-backup/config.env"
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file not found: $config_file" >&2
        return 1
    fi
    
    if [[ ! -r "$config_file" ]]; then
        echo "ERROR: Configuration file not readable: $config_file" >&2
        return 1
    fi
    
    local config_perms config_owner
    config_perms=$(stat -c '%a' "$config_file" 2>/dev/null)
    config_owner=$(stat -c '%U:%G' "$config_file" 2>/dev/null)
    
    if [[ "$config_owner" != "root:root" ]]; then
        echo "ERROR: Configuration file must be owned by root:root, got: $config_owner" >&2
        return 1
    fi
    
    if [[ "$config_perms" != "600" && "$config_perms" != "400" ]]; then
        echo "ERROR: Configuration file must have permissions 600 or 400, got: $config_perms" >&2
        return 1
    fi
        echo "WARNING: Configuration file should have permissions 600, got: $config_perms" >&2
    fi
    
    # shellcheck source=/dev/null
    source "$config_file"
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

# Validate a backup filename is safe (no path traversal, only safe chars)
# Usage: validate_backup_filename "filename.age"
validate_backup_filename() {
    local filename="$1"
    
    if [[ "$filename" == */* || "$filename" == *..* ]]; then
        log "ERROR: Invalid filename (path traversal detected): $filename"
        return 1
    fi
    
    if [[ ! "$filename" =~ ^[a-zA-Z0-9_.-]+\.age$ ]]; then
        log "ERROR: Invalid filename (must end in .age and contain only safe chars): $filename"
        return 1
    fi
    
    return 0
}

# Validate numeric input
# Usage: validate_numeric "value" "name"
validate_numeric() {
    local value="$1"
    local name="${2:-value}"
    
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log "ERROR: $name must be a positive integer, got: $value"
        return 1
    fi
    return 0
}
