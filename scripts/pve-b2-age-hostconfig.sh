#!/usr/bin/env bash
set -euo pipefail

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || source "/usr/local/lib/pve-b2-age/common.sh"

show_usage() {
    cat <<'EOF'
Usage: pve-b2-age-hostconfig.sh

Backup Proxmox host configuration to encrypted B2 storage.
Includes: /etc, /var/lib/pve-cluster, /root

This script is typically run via systemd timer (weekly recommended).
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_usage
    exit 0
fi

load_config || exit 1
LOG="${LOG:-/var/log/pve-b2-age.log}"
validate_config "RCLONE_REMOTE" "AGE_RECIPIENTS" || exit 1

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
REMOTE_HOSTCFG="${REMOTE_BASE}/hostconfig"
WORKDIR="${WORKDIR:-/var/tmp}"

need tar
need age
need rclone

log "Starting host configuration backup"

tmpdir=$(mktemp -d "${WORKDIR}/pve-hostcfg-XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

name="pve-hostcfg-${HOST}-$(date +%Y_%m_%d-%H_%M_%S).tar.zst"
archive="${tmpdir}/${name}"

log "Creating archive: $name"

# tar exit code 1 means "some files changed during read" (warning, not fatal)
# Exit codes > 1 are actual errors
tar_exit=0
tar -C / -caf "$archive" \
    --exclude='etc/pve/priv/authorized_keys' \
    --exclude='etc/pve/priv/known_hosts' \
    etc \
    var/lib/pve-cluster \
    root 2>>"$LOG" || tar_exit=$?

if [[ "$tar_exit" -gt 1 ]]; then
    log "ERROR: Failed to create archive (exit code $tar_exit)"
    exit 1
elif [[ "$tar_exit" -eq 1 ]]; then
    log "WARN: Archive created with warnings (some files changed during read)"
fi

size=$(stat -c '%s' "$archive")
log "Archive created: $(format_bytes "$size")"

dst="${REMOTE_HOSTCFG}/${name}.age"
log "Uploading encrypted archive to B2..."

if age -R "$AGE_RECIPIENTS" "$archive" | rclone rcat \
    --fast-list \
    --streaming-upload-cutoff "${RCAT_CUTOFF:-8M}" \
    --transfers 1 --checkers 8 \
    --retries 10 --low-level-retries 20 \
    "$dst" >>"$LOG" 2>&1; then
    log "Upload successful: $dst"
else
    log "ERROR: Upload failed"
    exit 1
fi

log "Host configuration backup completed"
exit 0
