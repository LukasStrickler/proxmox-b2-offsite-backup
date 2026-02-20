#!/usr/bin/env bash
set -euo pipefail

# pve-b2-age-prune.sh - Prune old backups based on retention policy

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || source "/usr/local/lib/pve-b2-age/common.sh"

show_usage() {
    cat <<'EOF'
Usage: pve-b2-age-prune.sh [options]

Prune old backups from B2 storage based on retention policy.

Options:
  -h, --help     Show this help message
  --dry-run      Show what would be deleted without actually deleting

Retention settings (from config.env):
  KEEP_DAILY     Number of daily backups to keep (default: 7)
  KEEP_MONTHLY   Number of monthly backups to keep (default: 1)
  KEEP_LOGS      Number of log files to keep (default: 30)

Examples:
  # Preview what would be deleted
  sudo pve-b2-age-prune.sh --dry-run

  # Run prune with current retention settings
  sudo pve-b2-age-prune.sh

Files are permanently deleted using --b2-hard-delete.
EOF
}

# Parse options
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_usage
            exit 1
            ;;
    esac
done

# Load configuration
load_config || exit 1

# Validate required configuration
validate_config "RCLONE_REMOTE" || exit 1

HOST="${HOST:-$(hostname -s)}"
REMOTE_BASE="${RCLONE_REMOTE}/${REMOTE_PREFIX:-proxmox}/${HOST}"
REMOTE_DAILY="${REMOTE_BASE}/daily"
REMOTE_MONTHLY="${REMOTE_BASE}/monthly"
REMOTE_LOGS="${REMOTE_BASE}/logs"
REMOTE_MANIFEST="${REMOTE_BASE}/manifest"

LOG="${LOG:-/var/log/pve-b2-age.log}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_MONTHLY="${KEEP_MONTHLY:-1}"
KEEP_LOGS="${KEEP_LOGS:-30}"

# Validate retention values: first check they are numeric, then coerce to base-10
# This ensures proper error messages even with set -e when values are non-numeric
for var_name in KEEP_DAILY KEEP_MONTHLY KEEP_LOGS; do
    value="${!var_name}"
    # Require one or more digits; reject empty or non-numeric values
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log "ERROR: $var_name must be a positive integer >= 1, got: '${value}'"
        exit 1
    fi
    # Coerce to base-10 to avoid octal interpretation and write back
    printf -v "$var_name" '%d' "$((10#$value))"
    if (( ${!var_name} < 1 )); then
        log "ERROR: $var_name must be a positive integer >= 1, got: ${!var_name}"
        exit 1
    fi
done

# Check dependencies
need rclone
need flock
need jq

# Create dedicated lock directory (root-only)
LOCK_DIR="/run/pve-b2-age"
mkdir -p "$LOCK_DIR"
chmod 700 "$LOCK_DIR"

# Acquire lock
exec 200>"${LOCK_DIR}/prune.lock"
if ! flock -n 200; then
    log "Prune already running, exiting"
    exit 0
fi

log "Starting prune (dry-run=$DRY_RUN)"
log "Retention: daily=$KEEP_DAILY, monthly=$KEEP_MONTHLY, logs=$KEEP_LOGS"

# When pruning daily/monthly, also delete the corresponding manifest so we don't leave orphans.
# Only delete manifest if backup deletion succeeded to avoid orphaning backups.
delete_excess() {
    local remote_dir="$1"
    local keep_count="$2"
    local pattern="${3:-\.age$}"
    local label="${4:-items}"
    local manifest_dir="${5:-}"
    
    log "Processing: $remote_dir (keep=$keep_count $label)"
    
    # Get list of files sorted by modification time (newest first)
    # Using lsjson to get ModTime for correct chronological ordering
    local files_json
    if ! files_json=$(rclone lsjson --files-only --fast-list "$remote_dir" 2>/dev/null); then
        log "  ERROR: Failed to list $remote_dir"
        return 1
    fi
    
    local files
    files=$(echo "$files_json" | jq -r --arg pattern "$pattern" \
        '[.[] | select(.Name | test($pattern))] | sort_by(.ModTime) | reverse | .[].Name' 2>/dev/null)
    
    if [[ -z "$files" ]]; then
        log "  No matching files found"
        return 0
    fi
    
    local total
    total=$(echo "$files" | grep -c '^' || true)
    
    if [[ -z "$files" || "$total" -eq 0 ]]; then
        log "  No matching files found"
        return 0
    fi
    
    log "  Found $total $label"
    
    if (( total <= keep_count )); then
        log "  Nothing to delete (total=$total <= keep=$keep_count)"
        return 0
    fi
    
    local to_delete=$(( total - keep_count ))
    log "  Deleting $to_delete oldest $label"
    
    # Get files to delete (skip the first 'keep_count' lines)
    local files_to_delete
    files_to_delete=$(echo "$files" | tail -n +$(( keep_count + 1 )))
    
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        
        local full_path="$remote_dir/$file"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "  [DRY-RUN] Would delete: $full_path"
            [[ -n "$manifest_dir" ]] && log "  [DRY-RUN] Would delete manifest: $manifest_dir/${file%.age}.json.age"
        else
            log "  Deleting: $full_path"
            if rclone deletefile --b2-hard-delete "$full_path" >>"$LOG" 2>&1; then
                # Only delete manifest if backup deletion succeeded
                if [[ -n "$manifest_dir" ]]; then
                    local manifest_file="${manifest_dir}/${file%.age}.json.age"
                    rclone deletefile --b2-hard-delete "$manifest_file" >>"$LOG" 2>&1 || \
                        log "    WARNING: Failed to delete manifest (may not exist) $manifest_file"
                fi
            else
                log "    WARNING: Failed to delete backup $file - keeping manifest"
            fi
        fi
    done <<< "$files_to_delete"
}

# Prune daily backups (and their manifests)
delete_excess "$REMOTE_DAILY" "$KEEP_DAILY" '\.age$' 'daily backups' "$REMOTE_MANIFEST"

# Prune monthly backups (with their own manifests now)
delete_excess "$REMOTE_MONTHLY" "$KEEP_MONTHLY" '\.age$' 'monthly backups' "$REMOTE_MONTHLY"

# Prune old logs (no manifest for log files)
delete_excess "$REMOTE_LOGS" "$KEEP_LOGS" '\.age$' 'log files'

# Cleanup uncommitted/hidden files on B2
if [[ "$DRY_RUN" == "false" ]]; then
    log "Running rclone cleanup..."
    rclone cleanup --b2-hard-delete "$(sanitize_path "$REMOTE_BASE")" >>"$LOG" 2>&1 || log "WARNING: Cleanup had issues"
fi

log "Prune completed"
exit 0
