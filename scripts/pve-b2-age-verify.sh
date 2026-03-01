#!/usr/bin/env bash
set -euo pipefail

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || source "/usr/local/lib/pve-b2-age/common.sh"

show_usage() {
    cat <<'EOF'
Usage: pve-b2-age-verify.sh [options] <TIER> <ENCRYPTED_BACKUP>

Verify integrity of an encrypted backup without full restore.
Decrypts and checks SHA256 hash against manifest.

Options:
  -h, --help        Show this help message
  --delete          Delete decrypted file after verification

Arguments:
  tier              "daily" or "monthly"
  encrypted_backup  The encrypted backup filename

Examples:
  pve-b2-age-verify.sh daily vzdump-qemu-101-2026_02_15-02_00_01.vma.zst.age
  pve-b2-age-verify.sh --delete monthly vzdump-qemu-101-2026_02_01-02_00_01.vma.zst.age
EOF
}

DELETE_AFTER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_usage; exit 0 ;;
        --delete) DELETE_AFTER=true; shift ;;
        daily|monthly) TIER="$1"; shift ;;
        *.age) ENC_NAME="$1"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${TIER:-}" || -z "${ENC_NAME:-}" ]]; then
    echo "ERROR: Missing required arguments" >&2
    show_usage
    exit 1
fi

ENC_NAME=$(basename "$ENC_NAME")

load_config || exit 1
validate_config "RCLONE_REMOTE" "AGE_IDENTITY" || exit 1

HOST="${HOST:-$(hostname -s)}"
REMOTE_BASE="${RCLONE_REMOTE}/${REMOTE_PREFIX:-proxmox}/${HOST}"
REMOTE_DIR="${REMOTE_BASE}/${TIER}"
REMOTE_MANIFEST="${REMOTE_BASE}/manifest"
# Parent directory for temp files; a unique subdir is created via mktemp
WORKDIR="${VERIFY_WORKDIR:-/var/tmp}"
LOG="${LOG:-/var/log/pve-b2-age-verify.log}"

validate_backup_filename "$ENC_NAME" || exit 1

need rclone
need age
need jq
need sha256sum

if [[ ! -f "$AGE_IDENTITY" ]]; then
    log "ERROR: Age identity file not found: $AGE_IDENTITY"
    exit 1
fi

# Create unique temp directory (prevents symlink attacks, avoids chmod on shared dirs)
tmpdir=$(mktemp -d "${WORKDIR}/pve-b2-age-verify-XXXXXX") || {
    log "ERROR: Failed to create temp directory"
    exit 1
}

local_enc="${tmpdir}/${ENC_NAME}"
local_plain="${tmpdir}/${ENC_NAME%.age}"
manifest_name="${ENC_NAME%.age}.json.age"
manifest_enc="${tmpdir}/${manifest_name}"
manifest_plain="${tmpdir}/${manifest_name%.age}"

# shellcheck disable=SC2329
cleanup() {
    [[ -f "$manifest_enc" ]] && rm -f "$manifest_enc" || true
    [[ -f "$manifest_plain" ]] && rm -f "$manifest_plain" || true
    [[ -f "$local_enc" ]] && rm -f "$local_enc" || true
    if [[ "$DELETE_AFTER" == "true" && -f "$local_plain" ]]; then
        rm -f "$local_plain" || true
        log "Decrypted file deleted"
    fi
    rmdir "$tmpdir" 2>/dev/null || true
}
trap cleanup EXIT

log "=== Verification Started ==="
log "Backup: $ENC_NAME"
log "Tier: $TIER"

log "Downloading encrypted backup..."
if ! rclone copyto --fast-list "${REMOTE_DIR}/${ENC_NAME}" "$local_enc"; then
    log "ERROR: Failed to download backup"
    exit 1
fi

log "Downloading manifest..."
# Use tier-aware manifest path (same logic as restore.sh)
# Monthly backups have manifests in the monthly directory
# Daily backups have manifests in the manifest directory
if [[ "$TIER" == "monthly" ]]; then
    manifest_remote_path="${REMOTE_DIR}/${manifest_name}"
else
    manifest_remote_path="${REMOTE_MANIFEST}/${manifest_name}"
fi
if ! rclone copyto --fast-list "$manifest_remote_path" "$manifest_enc"; then
    log "ERROR: Failed to download manifest"
    exit 1
fi

log "Decrypting manifest..."
if ! age -d -i "$AGE_IDENTITY" -o "$manifest_plain" "$manifest_enc"; then
    log "ERROR: Failed to decrypt manifest"
    exit 1
fi

if ! expected_sha=$(jq -r '.sha256' "$manifest_plain" 2>/dev/null); then
    log "ERROR: Failed to parse manifest JSON - sha256 field missing or invalid"
    exit 1
fi
if ! expected_size=$(jq -r '.size_bytes' "$manifest_plain" 2>/dev/null); then
    log "ERROR: Failed to parse manifest JSON - size_bytes field missing or invalid"
    exit 1
fi
if [[ "$expected_size" == "null" || ! "$expected_size" =~ ^[0-9]+$ ]]; then
    log "ERROR: Invalid manifest - size_bytes is missing or not numeric"
    exit 1
fi
if [[ "$expected_sha" == "null" || ${#expected_sha} -ne 64 || ! "$expected_sha" =~ ^[0-9a-fA-F]+$ ]]; then
    log "ERROR: Invalid manifest - sha256 is missing or malformed"
    exit 1
fi

log "Expected size: $expected_size bytes"
log "Expected SHA256: ${expected_sha:0:16}..."

log "Decrypting backup..."
if ! age -d -i "$AGE_IDENTITY" -o "$local_plain" "$local_enc"; then
    log "ERROR: Failed to decrypt backup"
    exit 1
fi

actual_size=$(stat -c '%s' "$local_plain")
if [[ "$actual_size" != "$expected_size" ]]; then
    log "ERROR: Size mismatch! Expected: $expected_size, Actual: $actual_size"
    exit 1
fi
log "Size verification: OK"

log "Computing SHA256 (this may take a while)..."
actual_sha=$(sha256sum "$local_plain" | awk '{print $1}')

if [[ "$actual_sha" != "$expected_sha" ]]; then
    log "ERROR: SHA256 mismatch!"
    log "  Expected: $expected_sha"
    log "  Actual:   $actual_sha"
    exit 1
fi

log "SHA256 verification: OK"
log "=== Verification Successful ==="

if [[ "$DELETE_AFTER" == "false" ]]; then
    log "Decrypted file kept at: $local_plain"
fi

exit 0
