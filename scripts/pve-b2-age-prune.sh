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

# Maximum allowed retention value to prevent overflow
MAX_KEEP_VALUE=100000

# Validate retention values: first coerce to base-10, then check bounds
for var_name in KEEP_DAILY KEEP_MONTHLY KEEP_LOGS KEEP_HOSTCONFIG; do
  value="${!var_name}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    log "ERROR: $var_name must be a non-negative integer, got: '${value}'"
    exit 1
  fi
  # Coerce to base-10 FIRST to handle leading zeros (e.g., 09)
  printf -v "$var_name" '%d' "$((10#$value))"
  # Now check for overflow risk
  if (( ${!var_name} > MAX_KEEP_VALUE )); then
    log "ERROR: $var_name exceeds maximum allowed value ($MAX_KEEP_VALUE), got: ${!var_name}"
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

# Acquire lock - exit with distinct code if already running
LOCK_EXIT_CODE=0  # Success by default
exec 200>"${LOCK_DIR}/prune.lock"
if ! flock -n 200; then
  log "Prune already running, exiting (skipped)"
  # Exit code 75 = EX_TEMPFAIL (temporary failure, can retry)
  exit 75
fi

log "Starting prune (dry-run=$DRY_RUN)"
log "Retention: daily=$KEEP_DAILY per VM, monthly=$KEEP_MONTHLY per VM, logs=$KEEP_LOGS, hostconfig=$KEEP_HOSTCONFIG"

# Track errors for final exit code
ERRORS_OCCURRED=0

# Track manifest references across tiers to prevent premature deletion
declare -A manifest_refs=()

# Index manifest references from a remote directory
# Returns 0 on success, 1 on failure (fail-closed)
index_manifest_refs() {
  local remote_dir="$1"
  local files_json name names
  
  # Capture only stdout from rclone; let stderr go to logs separately
  if ! files_json=$(rclone lsjson --files-only --fast-list "$remote_dir" 2>>"$LOG"); then
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
  # Capture stdout only; stderr goes to log separately to avoid JSON corruption
  local files_json
  if ! files_json=$(rclone lsjson --files-only --fast-list "$remote_dir" 2>>"$LOG"); then
    log "  ERROR: Failed to list $remote_dir"
    ((ERRORS_OCCURRED++))
    return 1
  fi
  
  # Get all .age files with their modification times, normalized to epoch for correct sorting
  # Exclude manifest files (*.json.age) from retention pool - they're handled separately
  local all_files
  if ! all_files=$(echo "$files_json" | jq -r '.[] | select(.Name | endswith(".age")) | select(.Name | endswith(".json.age") | not) | "\(.ModTime)|\(.Name)"'); then
    log "  ERROR: Failed to parse file list from rclone output"
    ((ERRORS_OCCURRED++))
    return 1
  fi
  
  if [[ -z "$all_files" ]]; then
    log "  No matching files found"
    return 0
  fi
  
  # Build associative array: vmid -> list of files with timestamps
  # Use newline as delimiter instead of comma to handle filenames with special chars
  declare -A vmid_files
  local line file vmid modtime
  
  while IFS='|' read -r modtime file; do
    [[ -z "$file" ]] && continue
    vmid=$(extract_vmid "$file")
    # Use newline delimiter to avoid issues with commas in filenames
    vmid_files["$vmid"]="${vmid_files["$vmid"]:-}${vmid_files["$vmid"]:+$'\n'}${modtime}|${file}"
  done <<< "$all_files"
  
  # Process each VMID's files
  local total_deleted=0
  for vmid in "${!vmid_files[@]}"; do
    # Skip unknown VMID bucket - don't prune files we can't identify
    if [[ "$vmid" == "unknown" ]]; then
      local unknown_count
      unknown_count=$(echo "${vmid_files[$vmid]}" | grep -c '^' || true)
      log "  VM unknown: $unknown_count backup(s) with non-standard names - skipping (manual review recommended)"
      continue
    fi
    
    # Sort by ModTime normalized to epoch (newest first), then extract filenames
    # Using jq to parse ISO8601 timestamps to epoch for correct chronological sorting
    local sorted_files
    sorted_files=$(echo "${vmid_files[$vmid]}" | jq -Rs 'split("\n") | map(select(length > 0) | split("|")) | sort_by(.[0] | fromdateiso8601? // 0) | reverse | .[] | select(length > 1) | .[1]' 2>/dev/null) || {
      # Fallback to lexical sort if jq parsing fails (e.g., non-standard timestamps)
      sorted_files=$(echo "${vmid_files[$vmid]}" | sort -t'|' -k1 -r | cut -d'|' -f2-)
    }
    
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
              # Delete manifest from current tier
              if ! rclone deletefile --b2-hard-delete "$manifest_file" >>"$LOG" 2>&1; then
                log "      WARNING: Failed to delete manifest (may not exist)"
              fi
              # Also delete from central manifest directory if pruning monthly
              # This prevents orphaned manifests when same backup existed in both tiers
              if [[ "$manifest_dir" == "$REMOTE_MONTHLY" && -n "$REMOTE_MANIFEST" ]]; then
                local central_manifest="${REMOTE_MANIFEST}/${file%.age}.json.age"
                rclone deletefile --b2-hard-delete "$central_manifest" >>"$LOG" 2>&1 || true
              fi
            else
              log "      Keeping manifest (still referenced by another tier)"
            fi
          fi
        else
          log "      ERROR: Failed to delete $file"
          ((ERRORS_OCCURRED++))
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
  # Capture stdout only; stderr goes to log separately
  if ! files_json=$(rclone lsjson --files-only --fast-list "$remote_dir" 2>>"$LOG"); then
    log "  ERROR: Failed to list $remote_dir"
    ((ERRORS_OCCURRED++))
    return 1
  fi
  
  local files
  if ! files=$(echo "$files_json" | jq -r '.[] | select(.Name | endswith(".age")) | "\(.ModTime)|\(.Name)"'); then
    log "  ERROR: Failed to parse file list from rclone output"
    ((ERRORS_OCCURRED++))
    return 1
  fi
  # Sort by ModTime normalized to epoch (newest first)
  files=$(echo "$files" | jq -Rs 'split("\n") | map(select(length > 0) | split("|")) | sort_by(.[0] | fromdateiso8601? // 0) | reverse | .[] | select(length > 1) | .[1]' 2>/dev/null) || {
    files=$(echo "$files" | sort -t'|' -k1 -r | cut -d'|' -f2-)
  }
  
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
      if ! rclone deletefile --b2-hard-delete "$full_path" >>"$LOG" 2>&1; then
        log "      ERROR: Failed to delete $file"
        ((ERRORS_OCCURRED++))
      fi
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
if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY-RUN] Would run: rclone cleanup --b2-hard-delete $REMOTE_BASE"
else
  log "Running rclone cleanup..."
  if ! rclone cleanup --b2-hard-delete "$(sanitize_path "$REMOTE_BASE")" >>"$LOG" 2>&1; then
    log "WARNING: Cleanup had issues"
    ((ERRORS_OCCURRED++))
  fi
fi

log "Prune completed"

# Exit with error code if any deletions failed
if (( ERRORS_OCCURRED > 0 )); then
  log "WARNING: $ERRORS_OCCURRED error(s) occurred during prune"
  exit 1
fi

exit 0
