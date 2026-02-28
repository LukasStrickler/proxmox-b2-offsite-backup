#!/usr/bin/env bash
set -euo pipefail

# pve-b2-age-restore-hostconfig.sh - Download and decrypt host config backup from B2
# Usage: pve-b2-age-restore-hostconfig.sh [--host HOST] [--extract-to DIR] [FILENAME.age]
# If filename is omitted, restores the latest backup by modification time.

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || source "/usr/local/lib/pve-b2-age/common.sh"

show_usage() {
    cat <<'EOF'
Usage: pve-b2-age-restore-hostconfig.sh [options] [FILENAME.age]

Download and decrypt a host configuration backup from B2.
If filename is omitted, the latest backup (by modification time) is used.

Options:
  -h, --help         Show this help message
  --host HOST        Hostname whose hostconfig to restore (default: current host)
  --extract-to DIR   After decrypting, extract the tarball into DIR (optional)

Arguments:
  FILENAME.age       Encrypted backup file (e.g. pve-hostcfg-pve1-2026_02_17-12_00_00.tar.zst.age)
                     Omit to use the latest backup.

Examples:
  # Restore latest host config, decrypt only
  sudo pve-b2-age-restore-hostconfig.sh

  # Restore specific file and extract to /tmp/hostconfig-restore
  sudo pve-b2-age-restore-hostconfig.sh --extract-to /tmp/hostconfig-restore \
    pve-hostcfg-pve1-2026_02_17-12_00_00.tar.zst.age

  # List available hostconfig backups first
  sudo pve-b2-age-list.sh hostconfig
EOF
}

HOST_FILTER=""
EXTRACT_TO=""
ENC_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_usage; exit 0 ;;
        --host) [[ -n "${2:-}" ]] || { echo "ERROR: --host requires a value" >&2; exit 1; }; HOST_FILTER="$2"; shift 2 ;;
        --extract-to) [[ -n "${2:-}" ]] || { echo "ERROR: --extract-to requires a value" >&2; exit 1; }; EXTRACT_TO="$2"; shift 2 ;;
        *.age) ENC_NAME="$1"; shift ;;
        *) echo "Unknown option: $1" >&2; show_usage; exit 1 ;;
    esac
done

load_config || exit 1
validate_config "RCLONE_REMOTE" "AGE_IDENTITY" || exit 1

HOST="${HOST:-$(hostname -s)}"
SEARCH_HOST="${HOST_FILTER:-$HOST}"
REMOTE_BASE="${RCLONE_REMOTE}/${REMOTE_PREFIX:-proxmox}/${SEARCH_HOST}"
REMOTE_HOSTCFG="${REMOTE_BASE}/hostconfig"
WORKDIR="${WORKDIR:-/var/tmp}"
EXTRACT_ALLOWED_BASES="${EXTRACT_ALLOWED_BASES:-/var/tmp:/tmp}"
LOG="${LOG:-/var/log/pve-b2-age.log}"

need rclone
need age
need jq
need tar
need realpath

if [[ ! -f "$AGE_IDENTITY" ]]; then
    log "ERROR: Age identity file not found: $AGE_IDENTITY"
    exit 1
fi

mkdir -p "$WORKDIR"
umask 077
restore_dir=$(mktemp -d "${WORKDIR}/pve-hostcfg-restore-XXXXXX")
trap '[[ -n "${restore_dir:-}" ]] && rm -rf "$restore_dir"' EXIT

if [[ -z "$ENC_NAME" ]]; then
    echo "Finding latest hostconfig backup for $SEARCH_HOST..."
    files_json=$(rclone lsjson --files-only "$REMOTE_HOSTCFG" 2>/dev/null) || files_json="[]"
    count=$(echo "$files_json" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
        echo "ERROR: No hostconfig backups found in $REMOTE_HOSTCFG" >&2
        echo "Run: pve-b2-age-list.sh --host $SEARCH_HOST hostconfig" >&2
        exit 1
    fi
    ENC_NAME=$(echo "$files_json" | jq -r 'sort_by(.ModTime) | reverse | .[0].Name')
    echo "Using latest: $ENC_NAME"
fi

ENC_NAME=$(basename "$ENC_NAME")
validate_backup_filename "$ENC_NAME" || exit 1

local_enc="${restore_dir}/${ENC_NAME}"
local_plain="${restore_dir}/${ENC_NAME%.age}"

echo "Downloading $ENC_NAME..."
if ! rclone copyto --fast-list --transfers 1 --checkers 8 \
    "${REMOTE_HOSTCFG}/${ENC_NAME}" "$local_enc"; then
    echo "ERROR: Failed to download backup" >&2
    exit 1
fi

echo "Decrypting..."
if ! age -d -i "$AGE_IDENTITY" -o "$local_plain" "$local_enc"; then
    echo "ERROR: Failed to decrypt (wrong key?)" >&2
    exit 1
fi

echo "Decrypted host config backup: $local_plain"

if [[ -n "$EXTRACT_TO" ]]; then
    validate_path_safe "$EXTRACT_TO" "extract path" || exit 1
    extract_realpath=$(realpath -m "$EXTRACT_TO")

    extract_allowed=false
    IFS=':' read -r -a allowed_bases <<< "$EXTRACT_ALLOWED_BASES"

    for base in "${allowed_bases[@]}"; do
        [[ -n "$base" ]] || continue
        base_realpath=$(realpath -m "$base")
        if [[ "$extract_realpath" == "$base_realpath"/* ]]; then
            extract_allowed=true
            break
        fi
    done

    if [[ "$extract_allowed" != "true" ]]; then
        echo "ERROR: --extract-to must be under an allowed base path: $EXTRACT_ALLOWED_BASES" >&2
        echo "  Got: $EXTRACT_TO" >&2
        exit 1
    fi

    mkdir -p "$EXTRACT_TO"
    echo "Extracting to $EXTRACT_TO..."
    tar -xaf "$local_plain" -C "$EXTRACT_TO"
    echo "Extracted. Review files under $EXTRACT_TO and copy what you need (e.g. etc/network/interfaces)."
else
    echo "To extract: tar -xaf $local_plain -C /EXTRACT_TARGET_DIR"
    echo "To extract specific files: tar -xaf $local_plain -C /tmp/restore etc/network/interfaces"
fi

# Copy out of trap dir so user can use after script exits (trap removes restore_dir)
final_plain="${WORKDIR}/$(basename "$local_plain")"
cp -a "$local_plain" "$final_plain"
echo ""
echo "Decrypted archive kept at: $final_plain"
echo "Remove when done: rm $final_plain"

exit 0
