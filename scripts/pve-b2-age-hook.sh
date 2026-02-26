#!/usr/bin/env bash
set -euo pipefail

# pve-b2-age-hook.sh - Proxmox vzdump hook for encrypted B2 backups
# This script is called by Proxmox during backup phases
# Documentation: see README.md and docs/

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || source "/usr/local/lib/pve-b2-age/common.sh"

PHASE="${1:-}"
MODE="${2:-}"
VMID="${3:-}"

# Load configuration
load_config || exit 1
LOG="${LOG:-/var/log/pve-b2-age.log}"

# Validate required configuration
validate_config "RCLONE_REMOTE" "DUMPDIR" "AGE_RECIPIENTS" || exit 1

if [[ ! -f "$AGE_RECIPIENTS" ]]; then
    log "ERROR: Age recipients file not found: $AGE_RECIPIENTS"
    exit 1
fi
if [[ ! -r "$AGE_RECIPIENTS" ]]; then
    log "ERROR: Age recipients file not readable: $AGE_RECIPIENTS"
    exit 1
fi

HOST="${HOST:-$(hostname -s)}"
REMOTE_BASE="${RCLONE_REMOTE}/${REMOTE_PREFIX:-proxmox}/${HOST}"
REMOTE_DAILY="${REMOTE_BASE}/daily"
REMOTE_MONTHLY="${REMOTE_BASE}/monthly"
REMOTE_LOGS="${REMOTE_BASE}/logs"
REMOTE_MANIFEST="${REMOTE_BASE}/manifest"

# Check dependencies
need age
need rclone
need flock
need sha256sum
need jq

# Create dedicated lock directory (root-only)
LOCK_DIR="/run/pve-b2-age"
LOCK_FILE="${LOCK_DIR}/hook.lock"
mkdir -p "$LOCK_DIR"
chmod 700 "$LOCK_DIR"

# Serialize hook actions to protect minimal staging design
exec 200>"$LOCK_FILE"
if ! flock -w 300 200; then
    log "ERROR: Could not acquire lock after 5 minutes"
    exit 1
fi

# In-flight marker file for TOCTOU-safe staging check
# This prevents race conditions where two jobs both pass the staging check
# before either creates a dump file
INFLIGHT_MARKER="${LOCK_DIR}/inflight"

# At backup-start: ensure staging has no other backup file (only one backup at a time).
# This protects limited staging (e.g. 100GB) when backing up many large VMs (e.g. 8x80GB).
# Space is only freed after upload in backup-end; overlapping jobs would fill the disk.
# Set ALLOW_CONCURRENT_STAGING=true in config to disable (only if staging is large enough).
staging_busy() {
    [[ "${ALLOW_CONCURRENT_STAGING:-false}" == "true" ]] && return 1
    
    # First check: is there an in-flight marker from another job?
    if [[ -f "$INFLIGHT_MARKER" ]]; then
        local marker_vmid
        marker_vmid=$(cat "$INFLIGHT_MARKER" 2>/dev/null || echo "unknown")
        log "ERROR: Staging busy — backup job for VMID $marker_vmid is in progress"
        return 0
    fi
    
    # Second check: are there existing dump files?
    local count
    count=$(find "$DUMPDIR" -maxdepth 1 -type f \( -name 'vzdump-qemu-*' -o -name 'vzdump-lxc-*' \) 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
        log "ERROR: Staging busy — $count backup file(s) already in $DUMPDIR (upload in progress or leftover)"
        return 0
    fi
    
    return 1
}

# Set in-flight marker (called at backup-start)
set_inflight() {
    echo "$VMID" > "$INFLIGHT_MARKER"
}

# Clear in-flight marker (called at backup-end or backup-abort)
clear_inflight() {
    rm -f "$INFLIGHT_MARKER" 2>/dev/null || true
}

upload_encrypted_stream() {
    local src_file="$1"
    local remote_path="$2"
    local filename
    filename=$(basename "$src_file")
    
    local file_size
    if ! file_size=$(stat -c '%s' "$src_file" 2>/dev/null); then
        log "ERROR: Cannot stat file: $src_file"
        return 1
    fi
    
    local sanitized_remote
    sanitized_remote=$(sanitize_path "$remote_path")
    
    log "Uploading encrypted: $filename ($(format_bytes "$file_size")) -> $remote_path"
    
    local attempt=1
    local max_attempts="${UPLOAD_ATTEMPTS:-6}"
    local base_delay="${BASE_BACKOFF:-20}"
    
    while true; do
        log "Upload attempt $attempt/$max_attempts: $filename"
        
        # Use single retry layer (outer backoff) - rclone uses --retries 1 to avoid nested retries
        # This prevents excessive blocking when network issues occur
        if age -R "$AGE_RECIPIENTS" "$src_file" 2>>"$LOG" | \
           rclone rcat \
               --fast-list \
               --streaming-upload-cutoff "${RCAT_CUTOFF:-8M}" \
               --transfers 4 \
               --checkers 8 \
               --retries 1 \
               --timeout 5m \
               --contimeout 1m \
               "$sanitized_remote" >>"$LOG" 2>&1; then
            return 0
        fi
        
        if (( attempt >= max_attempts )); then
            log "ERROR: All $max_attempts upload attempts failed for $filename"
            return 1
        fi
        
        local delay=$(( base_delay * (2 ** (attempt - 1)) ))
        log "Upload failed, waiting ${delay}s before retry..."
        sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
}

main() {
    case "$PHASE" in
        backup-start)
            if staging_busy; then
                log "ERROR: Only one backup at a time; schedule jobs so the next starts after the previous has finished and space is freed."
                exit 1
            fi
            # Set in-flight marker to prevent TOCTOU race
            set_inflight
            log "Backup started for VM/CT $VMID"
            ;;
            
        backup-end)
            # TARGET exists only at backup-end
            SRC="${TARGET:-${TARFILE:-}}"
            if [[ -z "$SRC" || ! -f "$SRC" ]]; then
                log "ERROR: TARGET/TARFILE missing or not a file: '${SRC:-<unset>}'"
                clear_inflight
                exit 1
            fi
            
            # Ensure inflight marker is cleared on any unexpected exit (set -e failures)
            trap clear_inflight EXIT
            
            local base_filename
            base_filename=$(basename "$SRC")
            local daily_object="${REMOTE_DAILY}/${base_filename}.age"
            
            # Get file info for manifest
            local size_bytes sha256_hash created_date
            size_bytes=$(stat -c '%s' "$SRC")
            sha256_hash=$(sha256sum "$SRC" | awk '{print $1}')
            created_date=$(date -Is)
            
            # Create manifest (for integrity verification during restore)
            local manifest_temp
            manifest_temp=$(mktemp)
            # shellcheck disable=SC2064
            trap 'clear_inflight; rm -f "$manifest_temp"' EXIT
            
            jq -n \
                --arg vmid "$VMID" \
                --arg host "$HOST" \
                --arg file "$base_filename" \
                --argjson size_bytes "$size_bytes" \
                --arg sha256 "$sha256_hash" \
                --arg created "$created_date" \
                --arg mode "$MODE" \
                '{vmid: $vmid, host: $host, file: $file, size_bytes: $size_bytes, sha256: $sha256, created: $created, mode: $mode}' > "$manifest_temp"
            
            local manifest_object="${REMOTE_MANIFEST}/${base_filename}.json.age"
            
            log "Starting encrypted upload: $base_filename (${size_bytes} bytes)"
            
            if upload_encrypted_stream "$SRC" "$daily_object"; then
                log "Backup upload successful: $base_filename"
                
                # Upload manifest
                if upload_encrypted_stream "$manifest_temp" "$manifest_object"; then
                    log "Manifest upload successful"
                else
                    log "ERROR: Manifest upload failed"
                    log "WARNING: Keeping local plaintext: $SRC"
                    log "WARNING: Re-run backup or manually delete after verifying remote backup"
                    clear_inflight
                    exit 1
                fi
                
                rm -f -- "$SRC"
                log "Deleted local plaintext backup: $SRC"
                
                if [[ "${ENABLE_MONTHLY:-true}" == "true" && "$(date +%d)" == "01" ]]; then
                    local monthly_object="${REMOTE_MONTHLY}/${base_filename}.age"
                    local monthly_manifest="${REMOTE_MONTHLY}/${base_filename}.json.age"
                    log "Creating monthly copy..."
                    if rclone copyto --fast-list --transfers 4 --checkers 8 \
                        "$(sanitize_path "$daily_object")" \
                        "$(sanitize_path "$monthly_object")" >>"$LOG" 2>&1; then
                        log "Monthly backup copy created"
                        if rclone copyto --fast-list --transfers 4 --checkers 8 \
                            "$(sanitize_path "$manifest_object")" \
                            "$(sanitize_path "$monthly_manifest")" >>"$LOG" 2>&1; then
                            log "Monthly manifest copy created"
                        else
                            log "ERROR: Monthly manifest copy failed, deleting inconsistent monthly backup copy"
                            # Use deletefile instead of delete for single-object removal (safer)
                            if ! rclone deletefile --b2-hard-delete "$(sanitize_path "$monthly_object")" >>"$LOG" 2>&1; then
                                log "ERROR: Failed to delete inconsistent monthly backup copy: $monthly_object"
                                log "WARNING: Monthly backup is in inconsistent state - manual cleanup required"
                                clear_inflight
                                exit 1
                            fi
                        fi
                    else
                        log "WARN: Monthly backup copy failed"
                    fi
                fi
                
                # Clear in-flight marker on success
                clear_inflight
                log "Backup completed successfully for VM/CT $VMID"
            else
                log "ERROR: Upload failed, keeping local plaintext: $SRC"
                clear_inflight
                exit 1
            fi
            ;;
            
        log-end)
            # LOGFILE exists only at log-end
            LF="${LOGFILE:-}"
            if [[ -n "$LF" && -f "$LF" ]]; then
                local log_basename
                log_basename=$(basename "$LF")
                local log_object="${REMOTE_LOGS}/${log_basename}.age"
                log "Uploading vzdump log: $log_basename"
                upload_encrypted_stream "$LF" "$log_object" || log "WARN: Log upload failed"
            fi
            ;;
            
        backup-abort)
            log "Backup aborted for VM/CT $VMID"
            clear_inflight
            if [[ -n "$VMID" && -n "${DUMPDIR:-}" ]]; then
                shopt -s nullglob
                for f in "$DUMPDIR"/vzdump-*"-$VMID-"*; do
                    log "Cleaning up aborted staging file: $f"
                    rm -f "$f" 2>/dev/null || true
                done
                shopt -u nullglob
            fi
            ;;
            
        *)
            log "WARNING: Unknown phase: $PHASE (may indicate Proxmox version incompatibility)"
            # Unknown phases are non-fatal - Proxmox may add new phases in future versions
            ;;
    esac
}

main "$@"

exit 0
