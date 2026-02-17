#!/usr/bin/env bash
set -euo pipefail

# pve-b2-age-restore.sh - Restore VMs/CTs from encrypted B2 backups
# Usage: pve-b2-age-restore.sh <daily|monthly> <encrypted_filename.age> <new_vmid> [storage]

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || source "/usr/local/lib/pve-b2-age/common.sh"

show_usage() {
    cat <<'EOF'
Usage: pve-b2-age-restore.sh <tier> <encrypted_backup> <new_vmid> [storage]

Arguments:
  tier            - "daily" or "monthly" (which backup tier to restore from)
  encrypted_backup - The encrypted backup filename (e.g., vzdump-qemu-101-2026_02_15-02_00_01.vma.zst.age)
  new_vmid        - The new VMID/CTID to restore to (must not exist)
  storage         - Optional: target storage (default: auto-detect or local-lvm)

Examples:
  # Restore from daily backups to VMID 201
  pve-b2-age-restore.sh daily vzdump-qemu-101-2026_02_15-02_00_01.vma.zst.age 201

  # Restore from monthly backups to VMID 201 on specific storage
  pve-b2-age-restore.sh monthly vzdump-qemu-101-2026_02_01-02_00_01.vma.zst.age 201 local-zfs

  # Restore a container
  pve-b2-age-restore.sh daily vzdump-lxc-102-2026_02_15-02_00_01.tar.zst.age 202

Note: The age private key must be available at AGE_IDENTITY in the config file.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_usage
    exit 0
fi

if [[ $# -lt 3 ]]; then
    echo "ERROR: Insufficient arguments" >&2
    show_usage
    exit 1
fi

TIER="$1"
ENC_NAME="$2"
NEW_ID="$3"
STORAGE="${4:-}"

# Validate tier
if [[ "$TIER" != "daily" && "$TIER" != "monthly" ]]; then
    echo "ERROR: Tier must be 'daily' or 'monthly'" >&2
    exit 1
fi

# Load configuration
CONFIG_FILE="${CONFIG_FILE:-/etc/pve-b2-age-backup/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# Validate required configuration
: "${RCLONE_REMOTE:?}" "${AGE_IDENTITY:?}"

HOST="${HOST:-$(hostname -s)}"
REMOTE_BASE="${RCLONE_REMOTE}/${REMOTE_PREFIX:-proxmox}/${HOST}"
REMOTE_DIR="${REMOTE_BASE}/${TIER}"
REMOTE_MANIFEST="${REMOTE_BASE}/manifest"
WORKDIR="${RESTORE_WORKDIR:-/var/lib/vz/dump}"
LOG="${LOG:-/var/log/pve-b2-age-restore.log}"

# Check dependencies
need rclone
need age
need jq
need sha256sum
need qm
need qmrestore
need pct

# Verify age identity exists
if [[ ! -f "$AGE_IDENTITY" ]]; then
    log "ERROR: Age identity file not found: $AGE_IDENTITY"
    log "The private key is required for decryption."
    log "If it's stored offline, copy it to this host temporarily."
    exit 1
fi

# Create work directory
mkdir -p "$WORKDIR"

local_enc="${WORKDIR}/${ENC_NAME}"
local_plain="${WORKDIR}/${ENC_NAME%.age}"
manifest_name="${ENC_NAME%.age}.json.age"
manifest_enc="${WORKDIR}/${manifest_name}"
manifest_plain="${WORKDIR}/${manifest_name%.age}"

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        log "Cleanup: preserving files for debugging (exit code: $exit_code)"
        log "  Encrypted: $local_enc"
        log "  Manifest: $manifest_enc"
        [[ -f "$local_plain" ]] && log "  Plaintext: $local_plain (exists)"
    else
        log "Cleanup: removing temporary files"
        rm -f "$local_enc" "$manifest_enc" "$manifest_plain" 2>/dev/null || true
        # Keep plaintext for user to delete after verification
        log "NOTE: Decrypted backup kept at: $local_plain"
        log "      Verify and delete manually when done."
    fi
}
trap cleanup EXIT

log "=== Restore Started ==="
log "Tier: $TIER"
log "Backup: $ENC_NAME"
log "Target VMID: $NEW_ID"
[[ -n "$STORAGE" ]] && log "Target Storage: $STORAGE"

# Check if target VMID already exists
if qm status "$NEW_ID" >/dev/null 2>&1 || pct status "$NEW_ID" >/dev/null 2>&1; then
    log "ERROR: Target VMID $NEW_ID already exists"
    exit 1
fi

# Download encrypted backup
log "Downloading encrypted backup from B2..."
if ! rclone copyto --fast-list --transfers 1 --checkers 8 \
    "${REMOTE_DIR}/${ENC_NAME}" "$local_enc"; then
    log "ERROR: Failed to download backup"
    exit 1
fi
log "Backup download complete ($(stat -c '%s' "$local_enc") bytes)"

# Download manifest
log "Downloading manifest..."
if ! rclone copyto --fast-list --transfers 1 --checkers 8 \
    "${REMOTE_MANIFEST}/${manifest_name}" "$manifest_enc"; then
    log "ERROR: Failed to download manifest"
    exit 1
fi

# Decrypt manifest
log "Decrypting manifest..."
if ! age -d -i "$AGE_IDENTITY" -o "$manifest_plain" "$manifest_enc"; then
    log "ERROR: Failed to decrypt manifest (wrong key?)"
    exit 1
fi

# Parse manifest
expected_sha=$(jq -r '.sha256' "$manifest_plain")
expected_size=$(jq -r '.size_bytes' "$manifest_plain")
original_vmid=$(jq -r '.vmid' "$manifest_plain")
original_host=$(jq -r '.host' "$manifest_plain")
backup_file=$(jq -r '.file' "$manifest_plain")
created_date=$(jq -r '.created' "$manifest_plain")

log "Manifest info:"
log "  Original VMID: $original_vmid"
log "  Original Host: $original_host"
log "  Created: $created_date"
log "  Expected size: $expected_size bytes"
log "  Expected SHA256: ${expected_sha:0:16}..."

# Decrypt backup
log "Decrypting backup (this may take a while)..."
if ! age -d -i "$AGE_IDENTITY" -o "$local_plain" "$local_enc"; then
    log "ERROR: Failed to decrypt backup (wrong key?)"
    exit 1
fi

# Verify size
actual_size=$(stat -c '%s' "$local_plain")
if [[ "$actual_size" != "$expected_size" ]]; then
    log "ERROR: Size mismatch!"
    log "  Expected: $expected_size"
    log "  Actual:   $actual_size"
    exit 1
fi
log "Size verification: OK ($actual_size bytes)"

# Verify hash (optional, can be slow on large files)
if [[ "${VERIFY_HASH:-true}" == "true" ]]; then
    log "Verifying SHA256 hash (this may take a while)..."
    actual_sha=$(sha256sum "$local_plain" | awk '{print $1}')
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        log "ERROR: SHA256 mismatch!"
        log "  Expected: $expected_sha"
        log "  Actual:   $actual_sha"
        exit 1
    fi
    log "Hash verification: OK"
else
    log "Skipping hash verification (VERIFY_HASH=false)"
fi

# Determine backup type and restore
if [[ "$local_plain" == *.vma* ]]; then
    log "Detected VM backup (vma format)"
    log "Restoring VM to ID $NEW_ID..."
    
    if [[ -n "$STORAGE" ]]; then
        qmrestore "$local_plain" "$NEW_ID" --storage "$STORAGE"
    else
        qmrestore "$local_plain" "$NEW_ID"
    fi
    
elif [[ "$local_plain" == *.tar* ]]; then
    log "Detected container backup (tar format)"
    log "Restoring CT to ID $NEW_ID..."
    
    if [[ -n "$STORAGE" ]]; then
        pct restore "$NEW_ID" "$local_plain" --storage "$STORAGE"
    else
        pct restore "$NEW_ID" "$local_plain"
    fi
else
    log "ERROR: Unknown backup format: $local_plain"
    exit 1
fi

log "=== Restore Completed Successfully ==="
log "VM/CT $NEW_ID restored from backup"
log "Original: VM $original_vmid from $original_host ($created_date)"

exit 0
