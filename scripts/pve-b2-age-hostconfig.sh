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
Includes: /etc, /var/lib/pve-cluster, /root, /usr/local/sbin, /usr/local/bin
If sqlite3 is available, includes a consistent snapshot of
/var/lib/pve-cluster/config.db in the archive.

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
snapshot_root="${tmpdir}/snapshot"
snapshot_db="${snapshot_root}/var/lib/pve-cluster/config.db"
use_db_snapshot=false
base_paths=("etc" "var/lib/pve-cluster" "root" "usr/local/sbin" "usr/local/bin")
archive_paths=()

for path in "${base_paths[@]}"; do
    if [[ -e "/${path}" ]]; then
        archive_paths+=("$path")
    fi
done

if [[ ${#archive_paths[@]} -eq 0 ]]; then
    log "ERROR: No host configuration paths found to archive"
    exit 1
fi

if command -v sqlite3 >/dev/null 2>&1; then
    mkdir -p "$(dirname "$snapshot_db")"
    if sqlite3 /var/lib/pve-cluster/config.db ".backup '$snapshot_db'" >>"$LOG" 2>&1; then
        use_db_snapshot=true
        log "Created consistent pmxcfs config.db snapshot"
    else
        log "WARNING: Failed to create sqlite snapshot, falling back to file-level config.db copy"
    fi
else
    log "WARNING: sqlite3 not found, using file-level /var/lib/pve-cluster copy"
fi

log "Creating archive: $name"

if [[ "$use_db_snapshot" == "true" ]]; then
    if ! tar -caf "$archive" \
        --exclude='etc/pve/priv/authorized_keys' \
        --exclude='etc/pve/priv/known_hosts' \
        --exclude='var/lib/pve-cluster/config.db' \
        -C / \
        "${archive_paths[@]}" \
        -C "$snapshot_root" \
        var/lib/pve-cluster/config.db 2>>"$LOG"; then
        log "ERROR: Failed to create archive"
        exit 1
    fi
else
    if ! tar -C / -caf "$archive" \
        --exclude='etc/pve/priv/authorized_keys' \
        --exclude='etc/pve/priv/known_hosts' \
        "${archive_paths[@]}" 2>>"$LOG"; then
        log "ERROR: Failed to create archive"
        exit 1
    fi
fi

if [[ "$use_db_snapshot" == "true" ]]; then
    log "Archive includes consistent /var/lib/pve-cluster/config.db snapshot"
fi

if [[ ! -s "$archive" ]]; then
    log "ERROR: Failed to create archive"
    exit 1
fi

size=$(stat -c '%s' "$archive")
log "Archive created: $(numfmt --to=iec-i "$size" 2>/dev/null || echo "${size}B")"

dst="${REMOTE_HOSTCFG}/${name}.age"
log "Uploading encrypted archive to B2..."

if age -R "$AGE_RECIPIENTS" "$archive" | rclone rcat \
    --streaming-upload-cutoff "${RCAT_CUTOFF:-8M}" \
    --retries 10 --low-level-retries 20 \
    "$dst" >>"$LOG" 2>&1; then
    log "Upload successful: $dst"
else
    log "ERROR: Upload failed"
    exit 1
fi

log "Host configuration backup completed"
exit 0
