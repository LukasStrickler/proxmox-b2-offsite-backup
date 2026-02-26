#!/usr/bin/env bash
set -euo pipefail

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || source "/usr/local/lib/pve-b2-age/common.sh"

show_usage() {
    cat <<'EOF'
Usage: pve-b2-age-list.sh [options] [tier]

List and browse encrypted backups stored in Backblaze B2

Options:
  -h, --help           Show this help message
  -j, --json           Output in JSON format
  -v, --verbose        Show detailed information
  -d, --download-info  Show download commands for each backup
  --host HOST          Filter by hostname (default: current host)
  --vmid ID            Filter by VMID/CTID

Arguments:
  tier                 "daily", "monthly", "logs", "manifest", "hostconfig", or "all"
                       (default: daily)

Examples:
  pve-b2-age-list.sh
  pve-b2-age-list.sh -v monthly
  pve-b2-age-list.sh --vmid 101 all
  pve-b2-age-list.sh -j daily
EOF
}

JSON_OUTPUT=false
VERBOSE=false
SHOW_DOWNLOAD=false
HOST_FILTER=""
VMID_FILTER=""
TIER="daily"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_usage; exit 0 ;;
        -j|--json) JSON_OUTPUT=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -d|--download-info) SHOW_DOWNLOAD=true; shift ;;
        --host) 
            [[ -n "${2:-}" ]] || { echo "ERROR: --host requires a value" >&2; exit 1; }
            # Validate hostname format (prevent path traversal)
            if [[ "$2" =~ /|\.\. || ! "$2" =~ ^[A-Za-z0-9._-]+$ ]]; then
                echo "ERROR: Invalid hostname format (only alphanumeric, dots, hyphens, underscores allowed)" >&2
                exit 1
            fi
            HOST_FILTER="$2"
            shift 2 
            ;;
        --vmid) 
            [[ -n "${2:-}" ]] || { echo "ERROR: --vmid requires a value" >&2; exit 1; }
            # Validate VMID is numeric only
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "ERROR: --vmid must be numeric" >&2
                exit 1
            fi
            VMID_FILTER="$2"
            shift 2 
            ;;
        daily|monthly|logs|manifest|hostconfig|all) TIER="$1"; shift ;;
        *) echo "Unknown option: $1" >&2; show_usage; exit 1 ;;
    esac
done

load_config || exit 1

validate_config "RCLONE_REMOTE" || exit 1

HOST="${HOST:-$(hostname -s)}"
SEARCH_HOST="${HOST_FILTER:-$HOST}"
REMOTE_BASE="${RCLONE_REMOTE}/${REMOTE_PREFIX:-proxmox}/${SEARCH_HOST}"

need rclone
need jq

declare -a TIERS_TO_LIST
if [[ "$TIER" == "all" ]]; then
    TIERS_TO_LIST=("daily" "monthly" "logs" "manifest" "hostconfig")
else
    TIERS_TO_LIST=("$TIER")
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo "{"
    echo "  \"host\": \"$SEARCH_HOST\","
    echo "  \"tiers\": {"
fi

first_tier=true
for current_tier in "${TIERS_TO_LIST[@]}"; do
    REMOTE_DIR="${REMOTE_BASE}/${current_tier}"
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        [[ "$first_tier" == "true" ]] || echo ","
        echo -n "    \"$current_tier\": ["
        first_tier=false
    else
        echo ""
        echo "=== ${current_tier^^} BACKUPS ==="
    fi
    
    if ! files_json=$(rclone lsjson --files-only --fast-list "$REMOTE_DIR" 2>/dev/null); then
        if [[ "$JSON_OUTPUT" != "true" ]]; then
            echo "  ERROR: Failed to list remote directory"
        fi
        files_json="[]"
    fi
    
    if [[ -n "$VMID_FILTER" && "$current_tier" != "hostconfig" ]]; then
        files_json=$(echo "$files_json" | jq --arg vmid "$VMID_FILTER" '[.[] | select(.Name | contains("-" + $vmid + "-"))]')
    fi
    
    file_count=$(echo "$files_json" | jq 'length')
    
    if [[ "$file_count" -eq 0 ]]; then
        if [[ "$JSON_OUTPUT" != "true" ]]; then
            echo "  No backups found"
        fi
        [[ "$JSON_OUTPUT" == "true" ]] && echo -n "]"
        continue
    fi
    
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        printf "  Found %d backup(s)\n\n" "$file_count"
    fi
    
    first_file=true
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        name=$(echo "$file" | jq -r '.Name')
        size=$(echo "$file" | jq -r '.Size')
        modtime=$(echo "$file" | jq -r '.ModTime')
        
        [[ "$name" != *.age ]] && continue
        
        backup_type="unknown"
        vmid="unknown"
        formatted_date="unknown"
        
        if [[ "$name" =~ vzdump-(qemu|lxc)-([0-9]+)-([0-9_]+)-([0-9_]+)\. ]]; then
            backup_type="${BASH_REMATCH[1]}"
            vmid="${BASH_REMATCH[2]}"
            formatted_date="${BASH_REMATCH[3]//_/-} ${BASH_REMATCH[4]//_/:}"
        fi
        
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            [[ "$first_file" == "true" ]] || echo -n ","
            first_file=false
            # Use jq for safe JSON encoding to prevent injection
            printf "\n      %s" "$(jq -c -n \
                --arg name "$name" \
                --argjson size "$size" \
                --arg modtime "$modtime" \
                --arg vmid "$vmid" \
                --arg type "$backup_type" \
                '{name: $name, size: $size, modtime: $modtime, vmid: $vmid, type: $type}')"
        else
            printf "  %-60s %10s\n" "$name" "$(format_bytes "$size")"
            if [[ "$VERBOSE" == "true" ]]; then
                printf "    Type: %-6s  VMID: %-6s  Date: %s\n" "$backup_type" "$vmid" "$formatted_date"
            fi
            if [[ "$SHOW_DOWNLOAD" == "true" ]]; then
                # Use printf %q to safely escape filenames for shell copy-paste
                local escaped_name escaped_remote
                escaped_name=$(printf '%q' "./${name}")
                escaped_remote=$(printf '%q' "${REMOTE_DIR}/${name}")
                echo "    Download: rclone copyto ${escaped_remote} ${escaped_name}"
                echo ""
        fi
    done < <(echo "$files_json" | jq -c '.[]')
    
    [[ "$JSON_OUTPUT" == "true" ]] && echo -e "\n    ]"
done

if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo "  }"
    echo "}"
else
    echo ""
    echo "=== SUMMARY ==="
    echo "Host: $SEARCH_HOST"
    echo "Remote: $RCLONE_REMOTE"
    echo "Tiers: ${TIERS_TO_LIST[*]}"
fi

exit 0
