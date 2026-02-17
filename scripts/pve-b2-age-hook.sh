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

# Validate required configuration
validate_config "RCLONE_REMOTE" "DUMPDIR" "AGE_RECIPIENTS" || exit 1

HOST="${HOST:-$(hostname -s)}"
REMOTE_BASE="${RCLONE_REMOTE}/${REMOTE_PREFIX:-proxmox}/${HOST}"
REMOTE_DAILY="${REMOTE_BASE}/daily"
REMOTE_MONTHLY="${REMOTE_BASE}/monthly"
REMOTE_LOGS="${REMOTE_BASE}/logs"
REMOTE_MANIFEST="${REMOTE_BASE}/manifest"

LOG="${LOG:-/var/log/pve-b2-age.log}"

# Check dependencies
need age
need rclone
need flock
need sha256sum
need jq

# Serialize hook actions to protect minimal staging design
exec 200>"/run/lock/pve-b2-age-hook.lock"
if ! flock -w 300 200; then
    log "ERROR: Could not acquire lock after 5 minutes"
    exit 1
fi

# At backup-start: ensure staging has no other backup file (only one backup at a time).
# This protects limited staging (e.g. 100GB) when backing up many large VMs (e.g. 8x80GB).
# Space is only freed after upload in backup-end; overlapping jobs would fill the disk.
# Set ALLOW_CONCURRENT_STAGING=true in config to disable (only if staging is large enough).
staging_busy() {
    [[ "${ALLOW_CONCURRENT_STAGING:-false}" == "true" ]] && return 1
    local count
    count=$(find "$DUMPDIR" -maxdepth 1 -type f \( -name 'vzdump-qemu-*' -o -name 'vzdump-lxc-*' \) 2>/dev/null | wc -l)
    [[ "$count" -gt 0 ]]
}

upload_encrypted_stream() {
    local src_file="$1"
    local remote_path="$2"
    local filename
    filename=$(basename "$src_file")
    
    log "Uploading encrypted: $filename -> $remote_path"
    
    local rclone_cmd="age -R \"$AGE_RECIPIENTS\" \"$src_file\" | rclone rcat"
    rclone_cmd+=" --fast-list"
    rclone_cmd+=" --streaming-upload-cutoff \"${RCAT_CUTOFF:-8M}\""
    rclone_cmd+=" --transfers 4"
    rclone_cmd+=" --checkers 8"
    rclone_cmd+=" --retries 5"
    rclone_cmd+=" --retries-sleep 10s"
    rclone_cmd+=" --low-level-retries 15"
    rclone_cmd+=" --timeout 5m"
    rclone_cmd+=" --contimeout 1m"
    rclone_cmd+=" \"$(sanitize_path "$remote_path")\""
    
    retry_with_backoff "$rclone_cmd" "${UPLOAD_ATTEMPTS:-6}" "${BASE_BACKOFF:-20}"
}

main() {
    case "$PHASE" in
        backup-start)
            if staging_busy; then
                log "ERROR: Staging busy — another backup file already in $DUMPDIR (upload in progress or leftover). Only one backup at a time; schedule jobs so the next starts after the previous has finished and space is freed."
                exit 1
            fi
            log "Backup started for VM/CT $VMID"
            ;;
            
        backup-end)
            # TARGET exists only at backup-end
            SRC="${TARGET:-${TARFILE:-}}"
            if [[ -z "$SRC" || ! -f "$SRC" ]]; then
                log "ERROR: TARGET/TARFILE missing or not a file: '${SRC:-<unset>}'"
                exit 1
            fi
            
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
            trap "rm -f '$manifest_temp'" EXIT
            
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
                    log "WARN: Manifest upload failed (backup is safe)"
                fi
                
                # Delete local plaintext only after successful upload
                rm -f -- "$SRC"
                log "Deleted local plaintext backup: $SRC"
                
                if [[ "${ENABLE_MONTHLY:-true}" == "true" && "$(date +%d)" == "01" ]]; then
                    local monthly_object="${REMOTE_MONTHLY}/${base_filename}.age"
                    log "Creating monthly copy..."
                    rclone copyto --fast-list --transfers 4 --checkers 8 \
                        "$(sanitize_path "$daily_object")" \
                        "$(sanitize_path "$monthly_object")" >>"$LOG" 2>&1 || \
                        log "WARN: Monthly copy failed"
                fi
                
                log "Backup completed successfully for VM/CT $VMID"
            else
                log "ERROR: Upload failed, keeping local plaintext: $SRC"
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
            ;;
            
        *)
            log "Unknown phase: $PHASE"
            ;;
    esac
}

main "$@"

exit 0
