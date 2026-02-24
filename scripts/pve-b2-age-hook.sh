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
MANIFEST_TEMP=""

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

HOST="${HOST:-${HOSTNAME:-$(hostname -s)}}"
REMOTE_BASE="${RCLONE_REMOTE}/${REMOTE_PREFIX:-proxmox}/${HOST}"
REMOTE_DAILY="${REMOTE_BASE}/daily"
REMOTE_MONTHLY="${REMOTE_BASE}/monthly"
REMOTE_LOGS="${REMOTE_BASE}/logs"
REMOTE_MANIFEST="${REMOTE_BASE}/manifest"
ACTIVE_MARKER="${DUMPDIR}/.pve-b2-age-active"

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

create_staging_marker() {
    [[ "${ALLOW_CONCURRENT_STAGING:-false}" == "true" ]] && return 0
    printf 'vmid=%s mode=%s ts=%s\n' "${VMID:-unknown}" "${MODE:-unknown}" "$(date -Is)" > "$ACTIVE_MARKER" || {
        log "ERROR: Failed to create staging marker: $ACTIVE_MARKER"
        exit 1
    }
}

clear_staging_marker() {
    [[ "${ALLOW_CONCURRENT_STAGING:-false}" == "true" ]] && return 0
    rm -f "$ACTIVE_MARKER" 2>/dev/null || true
}

cleanup_backup_end() {
    clear_staging_marker
    [[ -n "$MANIFEST_TEMP" && -f "$MANIFEST_TEMP" ]] && rm -f "$MANIFEST_TEMP"
}

upload_encrypted_stream_once() {
    local src_file="$1"
    local remote_path="$2"

 age -R "$AGE_RECIPIENTS" "$src_file" | \
    rclone rcat \
    --streaming-upload-cutoff "${RCAT_CUTOFF:-8M}" \
    --retries 5 \
    --retries-sleep 10s \
    --low-level-retries 15 \
    --timeout 5m \
    --contimeout 1m \
    "$(sanitize_path "$remote_path")"
}

upload_encrypted_stream() {
    local src_file="$1"
    local remote_path="$2"
    local filename
    filename=$(basename "$src_file")

    log "Uploading encrypted: $filename -> $remote_path"

    retry_with_backoff_fn upload_encrypted_stream_once "${UPLOAD_ATTEMPTS:-6}" "${BASE_BACKOFF:-20}" "$src_file" "$remote_path"
}

main() {
    case "$PHASE" in
        backup-start)
            if [[ -f "$ACTIVE_MARKER" ]]; then
                if staging_busy; then
                    local marker_state
                    marker_state=$(cat "$ACTIVE_MARKER" 2>/dev/null || echo "unknown")
                    log "ERROR: Staging marker present: $marker_state"
                    log "ERROR: Another backup is already active for this staging area"
                    exit 1
                else
                    local now marker_mtime marker_age max_marker_age marker_state
                    now=$(date +%s)
                    marker_mtime=$(stat -c '%Y' "$ACTIVE_MARKER" 2>/dev/null || echo 0)
                    marker_age=$(( now - marker_mtime ))
                    max_marker_age="${STAGING_MARKER_MAX_AGE:-21600}"
                    marker_state=$(cat "$ACTIVE_MARKER" 2>/dev/null || echo "unknown")
                    if (( marker_age > max_marker_age )); then
                        log "WARNING: Found stale staging marker (${marker_age}s old): $marker_state"
                        log "WARNING: Clearing stale marker: $ACTIVE_MARKER"
                        clear_staging_marker
                    else
                        log "ERROR: Recent staging marker present (${marker_age}s old): $marker_state"
                        log "ERROR: Another backup may be starting; refusing concurrent staging"
                        exit 1
                    fi
                fi
            fi
            if staging_busy; then
                log "ERROR: Staging busy — another backup file already in $DUMPDIR (upload in progress or leftover). Only one backup at a time; schedule jobs so the next starts after the previous has finished and space is freed."
                exit 1
            fi
            create_staging_marker
            log "Backup started for VM/CT $VMID"
            ;;
            
        backup-end)
            trap cleanup_backup_end EXIT
            # TARGET exists only at backup-end
            SRC="${TARGET:-${TARFILE:-}}"
            if [[ -z "$SRC" || ! -f "$SRC" ]]; then
                log "ERROR: TARGET/TARFILE missing or not a file: '${SRC:-<unset>}'"
                if [[ -n "${TARGET:-}" && ! -f "${TARGET}" ]]; then
                    log "ERROR: TARGET is not a local file path. This hook requires file-based vzdump staging (DUMPDIR) and is not compatible with PBS stream targets."
                fi
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
            MANIFEST_TEMP=$(mktemp)
            
            jq -n \
                --arg vmid "$VMID" \
                --arg host "$HOST" \
                --arg file "$base_filename" \
                --argjson size_bytes "$size_bytes" \
                --arg sha256 "$sha256_hash" \
                --arg created "$created_date" \
                --arg mode "$MODE" \
                '{vmid: $vmid, host: $host, file: $file, size_bytes: $size_bytes, sha256: $sha256, created: $created, mode: $mode}' > "$MANIFEST_TEMP"
            
            local manifest_object="${REMOTE_MANIFEST}/${base_filename}.json.age"
            
            log "Starting encrypted upload: $base_filename (${size_bytes} bytes)"
            
            if upload_encrypted_stream "$SRC" "$daily_object"; then
                log "Backup upload successful: $base_filename"
                
                # Upload manifest
                local manifest_ok=false
                if upload_encrypted_stream "$MANIFEST_TEMP" "$manifest_object"; then
                    log "Manifest upload successful"
                    manifest_ok=true
                else
                    log "ERROR: Manifest upload failed (backup data is safe in B2, but integrity verification will not be possible)"
                fi
                
                if [[ "$manifest_ok" == "true" ]]; then
                    rm -f -- "$SRC"
                    log "Deleted local plaintext backup: $SRC"
                else
                    log "WARNING: Keeping local plaintext due to manifest failure: $SRC"
                    log "WARNING: Re-run backup or manually delete after verifying remote backup"
                fi
                
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
            clear_staging_marker
            log "Backup aborted for VM/CT $VMID"
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
            ;;
    esac
}

main "$@"

exit 0
