#!/usr/bin/env bash
set -euo pipefail

# pve-b2-age-prune.sh - Prune old backups based on retention policy
# Uses per-VMID retention: each VM keeps its own specified number of backups

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || source "/usr/local/lib/pve-b2-age/common.sh"

show_usage() {
  cat <<'EOF'
Usage: pve-b2-age-prune.sh [options]

Prune old backups from B2 storage based on retention policy.

Options:
  -h, --help      Show this help message
  --dry-run       Show what would be deleted without actually deleting

Retention settings (from config.env):
  KEEP_DAILY            Number of daily backups per VM to keep (default: 7)
  KEEP_MONTHLY          Number of monthly backups per VM to keep (default: 1)
  KEEP_LOGS             Number of log files to keep (default: 30)
  KEEP_HOSTCONFIG       Number of hostconfig backups to keep (default: 4)

Note: Retention is applied PER VM ID, not globally. Each VM keeps its own
      specified number of backups independently of other VMs.

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
REMOTE_HOSTCONFIG="${REMOTE_BASE}/hostconfig"

LOG="${LOG:-/var/log/pve-b2-age.log}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_MONTHLY="${KEEP_MONTHLY:-1}"
KEEP_LOGS="${KEEP_LOGS:-30}"
KEEP_HOSTCONFIG="${KEEP_HOSTCONFIG:-4}"

# Validate retention values: first check they are numeric, then coerce to base-10
for var_name in KEEP_DAILY KEEP_MONTHLY KEEP_LOGS KEEP_HOSTCONFIG; do
  value="${!var_name}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    log "ERROR: $var_name must be a non-negative integer, got: '${value}'"
    exit 1
  fi
  printf -v "$var_name" '%d' "$((10#$value))"
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
log "Retention: daily=$KEEP_DAILY per VM, monthly=$KEEP_MONTHLY per VM, logs=$KEEP_LOGS, hostconfig=$KEEP_HOSTCONFIG"

# Track manifest references across tiers to prevent premature deletion
declare -A manifest_refs=()

# Index manifest references from a remote directory
# Returns 0 on success, 1 on failure (fail-closed)
index_manifest_refs() {
  local remote_dir="$1"
  local files_json name names
  
  # Capture only stdout from rclone; let stderr go to logs
  if ! files_json=$(rclone lsjson --files-only --fast-list "$remote_dir"); then
    log "ERROR: Failed to list $remote_dir"
    return 1
  fi
  
  # Parse JSON file list; fail if jq cannot parse (fail-closed)
  if ! names=$(printf '%s\n' "$files_json" | jq -r '.[].Name'); then
    log "ERROR: Failed to parse file list JSON for $remote_dir"
    return 1
  fi

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ "$name" == *.age ]] || continue
    manifest_refs["$name"]=$(( ${manifest_refs["$name"]:-0} + 1 ))
  done <<< "$names"
  
  return 0
}

# Index manifest references - abort if either tier fails to list (fail-closed)
if ! index_manifest_refs "$REMOTE_DAILY"; then
  log "ERROR: Failed to index daily backups - aborting prune to prevent data loss"
  exit 1
fi
if ! index_manifest_refs "$REMOTE_MONTHLY"; then
  log "ERROR: Failed to index monthly backups - aborting prune to prevent data loss"
  exit 1
fi

# Extract VMID from vzdump filename
# Pattern: vzdump-(qemu|lxc)-{VMID}-{date}-{time}.{ext}.age
extract_vmid() {
  local filename="$1"
  if [[ "$filename" =~ vzdump-(qemu|lxc)-([0-9]+)- ]]; then
    echo "${BASH_REMATCH[2]}"
  else
    echo "unknown"
  fi
}

# Delete excess backups with per-VMID retention
delete_excess_per_vmid() {
  local remote_dir="$1"
  local keep_count="$2"
  local tier_label="$3"
  local manifest_dir="$4"
  
  log "Processing: $remote_dir (keep=$keep_count backups per VM)"
  
  # Get all files from remote using lsjson for ModTime sorting
  local files_json
  if ! files_json=$(rclone lsjson --files-only --fast-list "$remote_dir" 2>&1); then
    log "  ERROR: Failed to list $remote_dir: $files_json"
    return 1
  fi
  
  # Get all .age files with their modification times
  local all_files
  all_files=$(echo "$files_json" | jq -r '.[] | select(.Name | endswith(".age")) | "\(.ModTime)|\(.Name)"' 2>/dev/null)
  
  if [[ -z "$all_files" ]]; then
    log "  No matching files found"
    return 0
  fi
  
  # Build associative array: vmid -> list of files with timestamps
  declare -A vmid_files
  local line file vmid modtime
  
  while IFS='|' read -r modtime file; do
    [[ -z "$file" ]] && continue
    vmid=$(extract_vmid "$file")
    vmid_files["$vmid"]="${vmid_files["$vmid"]:-}${vmid_files["$vmid"]:+,}${modtime}|${file}"
  done <<< "$all_files"
  
  # Process each VMID's files
  local total_deleted=0
  for vmid in "${!vmid_files[@]}"; do
    # Skip unknown VMID bucket - don't prune files we can't identify
    if [[ "$vmid" == "unknown" ]]; then
      local unknown_count
      unknown_count=$(echo "${vmid_files[$vmid]}" | tr ',' '\n' | grep -c '^' || true)
      log "  VM unknown: $unknown_count backup(s) with non-standard names - skipping (manual review recommended)"
      continue
    fi
    
    # Sort by ModTime (newest first) and extract filenames
    local sorted_files
    sorted_files=$(echo "${vmid_files[$vmid]}" | tr ',' '\n' | sort -t'|' -k1 -r | cut -d'|' -f2)
    
    local vm_total
    vm_total=$(echo "$sorted_files" | grep -c '^' || true)
    
    if [[ "$vm_total" -le "$keep_count" ]]; then
      log "  VM $vmid: $vm_total backup(s), keeping all (limit: $keep_count)"
      continue
    fi
    
    local to_delete=$(( vm_total - keep_count ))
    log "  VM $vmid: $vm_total backup(s), deleting $to_delete oldest (keeping $keep_count)"
    
    # Get files to delete (skip the first 'keep_count' lines)
    local files_to_delete
    files_to_delete=$(echo "$sorted_files" | tail -n +$(( keep_count + 1 )))
    
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      
      local full_path="$remote_dir/$file"
      # Default to 999 (keep manifest) if ref count unknown - fail-safe for unindexed files
      local manifest_remaining=$(( ${manifest_refs["$file"]:-999} - 1 ))
      
      if [[ "$DRY_RUN" == "true" ]]; then
        log "    [DRY-RUN] Would delete: $file"
        if [[ -n "$manifest_dir" ]]; then
          if (( manifest_remaining <= 0 )); then
            log "    [DRY-RUN] Would delete manifest: ${file%.age}.json.age"
          else
            log "    [DRY-RUN] Would keep manifest (referenced elsewhere): ${file%.age}.json.age"
          fi
        fi
        manifest_refs["$file"]="$manifest_remaining"
      else
        log "    Deleting: $file"
        if rclone deletefile --b2-hard-delete "$full_path" >>"$LOG" 2>&1; then
          manifest_refs["$file"]="$manifest_remaining"
          ((total_deleted++))
          if [[ -n "$manifest_dir" ]]; then
            local manifest_file="${manifest_dir}/${file%.age}.json.age"
            if (( manifest_remaining <= 0 )); then
              rclone deletefile --b2-hard-delete "$manifest_file" >>"$LOG" 2>&1 || \
                log "      WARNING: Failed to delete manifest (may not exist)"
            else
              log "      Keeping manifest (still referenced by another tier)"
            fi
          fi
        else
          log "      WARNING: Failed to delete $file"
        fi
      fi
    done <<< "$files_to_delete"
  done
  
  log "  Deleted $total_deleted files from $tier_label"
}

# Delete excess files with global retention (for logs and hostconfig)
delete_excess_global() {
  local remote_dir="$1"
  local keep_count="$2"
  local label="$3"
  
  log "Processing: $remote_dir (keep=$keep_count $label total)"
  
  local files_json
  if ! files_json=$(rclone lsjson --files-only --fast-list "$remote_dir" 2>&1); then
    log "  ERROR: Failed to list $remote_dir: $files_json"
    return 1
  fi
  
  local files
  files=$(echo "$files_json" | jq -r '.[] | select(.Name | endswith(".age")) | "\(.ModTime)|\(.Name)"' | sort -t'|' -k1 -r | cut -d'|' -f2)
  
  if [[ -z "$files" ]]; then
    log "  No matching files found"
    return 0
  fi
  
  local total
  total=$(echo "$files" | grep -c '^' || true)
  
  if [[ "$total" -le "$keep_count" ]]; then
    log "  Nothing to delete (total=$total <= keep=$keep_count)"
    return 0
  fi
  
  local to_delete=$(( total - keep_count ))
  log "  Deleting $to_delete oldest $label"
  
  local files_to_delete
  files_to_delete=$(echo "$files" | tail -n +$(( keep_count + 1 )))
  
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local full_path="$remote_dir/$file"
    
    if [[ "$DRY_RUN" == "true" ]]; then
      log "    [DRY-RUN] Would delete: $file"
    else
      log "    Deleting: $file"
      rclone deletefile --b2-hard-delete "$full_path" >>"$LOG" 2>&1 || \
        log "      WARNING: Failed to delete $file"
    fi
  done <<< "$files_to_delete"
}

# Prune daily backups (per-VM retention with manifest reference counting)
delete_excess_per_vmid "$REMOTE_DAILY" "$KEEP_DAILY" "daily backups" "$REMOTE_MANIFEST"

# Prune monthly backups (per-VM retention, manifests in monthly dir)
delete_excess_per_vmid "$REMOTE_MONTHLY" "$KEEP_MONTHLY" "monthly backups" "$REMOTE_MONTHLY"

# Prune old logs (global retention - logs are not per-VM)
delete_excess_global "$REMOTE_LOGS" "$KEEP_LOGS" "log files"

# Prune hostconfig backups (global retention - weekly archives)
delete_excess_global "$REMOTE_HOSTCONFIG" "$KEEP_HOSTCONFIG" "hostconfig backups"

# Cleanup uncommitted/hidden files on B2
if [[ "$DRY_RUN" == "false" ]]; then
  log "Running rclone cleanup..."
  rclone cleanup --b2-hard-delete "$(sanitize_path "$REMOTE_BASE")" >>"$LOG" 2>&1 || log "WARNING: Cleanup had issues"
fi

log "Prune completed"
exit 0
