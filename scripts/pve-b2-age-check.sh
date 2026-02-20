#!/usr/bin/env bash
set -euo pipefail

# pve-b2-age-check.sh - Pre-flight validation for PVE B2 Age Backup
# Usage: pve-b2-age-check.sh [--verbose] [--help]

# Source shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || source "/usr/local/lib/pve-b2-age/common.sh"

show_help() {
    cat <<'EOF'
PVE B2 Age Backup - Pre-flight Check

Usage: pve-b2-age-check.sh [options]

Options:
  -v, --verbose    Show detailed output
  -h, --help       Show this help message

This script validates your PVE B2 Age Backup configuration
and checks for common issues before running backups.

Exit codes:
  0 - All checks passed
  1 - One or more checks failed
EOF
}

VERBOSE=false
PASS=0
FAIL=0
WARN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}✗${NC} $*"; FAIL=$((FAIL + 1)); }
warn() { echo -e "${YELLOW}!${NC} $*"; WARN=$((WARN + 1)); }
info() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "  $*"
    fi
}

check_dependencies() {
    echo ""
    echo "=== Dependencies ==="
    
    local deps=("rclone" "age" "jq" "flock" "sha256sum")
    
    for dep in "${deps[@]}"; do
        if command -v "$dep" >/dev/null 2>&1; then
            pass "$dep installed"
            info "$(command -v "$dep")"
        else
            fail "$dep not found - install with: apt install $dep"
        fi
    done
}

check_config_file() {
    echo ""
    echo "=== Configuration ==="
    
    # Use hardcoded path for security - no CONFIG_FILE env override
    local config_file="/etc/pve-b2-age-backup/config.env"
    
    if [[ ! -f "$config_file" ]]; then
        fail "Config file not found: $config_file"
        return
    fi
    
    pass "Config file exists: $config_file"
    
    # Check ownership (must be root:root for security)
    local owner
    owner=$(stat -c '%U:%G' "$config_file" 2>/dev/null)
    if [[ "$owner" != "root:root" ]]; then
        fail "Config file must be owned by root:root (got: $owner)"
        return
    fi
    pass "Config file owned by root:root"
    
    if [[ ! -r "$config_file" ]]; then
        fail "Config file not readable (permission denied)"
        return
    fi
    
    pass "Config file readable"
    
    # Source and check required variables using secure load_config
    if ! load_config 2>/dev/null; then
        fail "Failed to load config (check permissions/ownership)"
        return
    fi
    
    local required_vars=("RCLONE_REMOTE" "AGE_RECIPIENTS")
    for var in "${required_vars[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            pass "$var is set"
            info "${!var}"
        else
            fail "$var is not set"
        fi
    done
    
    if [[ -n "${DUMPDIR:-}" ]]; then
        pass "DUMPDIR is set: $DUMPDIR"
    else
        warn "DUMPDIR is not set (using default)"
    fi
}

check_rclone_config() {
    echo ""
    echo "=== Rclone Configuration ==="
    
    if [[ -z "${RCLONE_REMOTE:-}" ]]; then
        fail "RCLONE_REMOTE not set - cannot check rclone config"
        return
    fi
    
    local remote_name="${RCLONE_REMOTE%%:*}"
    
    if rclone config show "$remote_name" >/dev/null 2>&1; then
        pass "Rclone remote '$remote_name' is configured"
        info "Remote: $RCLONE_REMOTE"
    else
        fail "Rclone remote '$remote_name' not found"
        info "Run: rclone config"
    fi
}

check_age_keys() {
    echo ""
    echo "=== Age Encryption Keys ==="
    
    local recipients_file="${AGE_RECIPIENTS:-/etc/pve-b2-age-backup/recipients.txt}"
    local identity_file="${AGE_IDENTITY:-/etc/pve-b2-age-backup/age.key}"
    
    # Check recipients (public keys)
    if [[ -f "$recipients_file" ]]; then
        local key_count
        key_count=$(grep -c "^age1" "$recipients_file" 2>/dev/null || echo "0")
        if [[ "$key_count" -gt 0 ]]; then
            pass "Recipients file exists with $key_count key(s)"
            info "$recipients_file"
        else
            fail "Recipients file exists but contains no valid keys"
        fi
    else
        fail "Recipients file not found: $recipients_file"
        info "Generate with: age-keygen -o age.key && grep -oE 'age1[0-9a-z]+' age.key > recipients.txt"
    fi
    
    # Check identity (private key) - optional for backup host
    if [[ -f "$identity_file" ]]; then
        if [[ "$(stat -c '%a' "$identity_file" 2>/dev/null)" == "600" ]]; then
            pass "Identity file exists with correct permissions (0600)"
        else
            warn "Identity file exists but permissions should be 0600"
            info "Run: chmod 600 $identity_file"
        fi
        info "$identity_file"
    else
        warn "Identity file not found (OK for backup-only host)"
        info "Required for restore: $identity_file"
    fi
}

check_staging_space() {
    echo ""
    echo "=== Staging Storage ==="
    
    local dumpdir="${DUMPDIR:-/backup/vzdump}"
    
    if [[ -d "$dumpdir" ]]; then
        pass "Staging directory exists: $dumpdir"
        
        local available_kb
        if ! available_kb=$(df -k "$dumpdir" 2>/dev/null | awk 'NR==2 {print $4}'); then
            warn "Could not determine available space for: $dumpdir"
            return
        fi
        
        if [[ -n "$available_kb" ]]; then
            local available_gb=$((available_kb / 1024 / 1024))
            if (( available_gb >= 50 )); then
                pass "Staging space: ${available_gb}GB available"
            elif (( available_gb >= 10 )); then
                warn "Staging space: ${available_gb}GB available (consider more for large VMs)"
            else
                fail "Staging space: ${available_gb}GB available (insufficient)"
            fi
        fi
    else
        warn "Staging directory not found: $dumpdir"
        info "Create with: mkdir -p $dumpdir"
    fi
}

check_hook_script() {
    echo ""
    echo "=== Hook Script ==="
    
    local hook_script="/usr/local/sbin/pve-b2-age-hook.sh"
    
    if [[ -f "$hook_script" ]]; then
        pass "Hook script installed: $hook_script"
        
        if [[ -x "$hook_script" ]]; then
            pass "Hook script is executable"
        else
            warn "Hook script is not executable"
            info "Run: chmod +x $hook_script"
        fi
    else
        fail "Hook script not installed: $hook_script"
        info "Run: ./install.sh"
    fi
}

check_systemd_timers() {
    echo ""
    echo "=== Systemd Timers ==="
    
    local timers=("pve-b2-age-prune.timer" "pve-b2-age-hostconfig.timer")
    
    for timer in "${timers[@]}"; do
        if systemctl list-unit-files "$timer" >/dev/null 2>&1; then
            if systemctl is-enabled "$timer" >/dev/null 2>&1; then
                pass "$timer is enabled"
            else
                warn "$timer exists but not enabled"
                info "Run: systemctl enable --now $timer"
            fi
        else
            warn "$timer not found"
            info "Run: ./install.sh to install timers"
        fi
    done
}

check_b2_recommendations() {
    echo ""
    echo "=== B2 Best Practices ==="
    
    warn "Ensure B2 bucket has lifecycle rule to clean incomplete multipart uploads (7 days)"
    info "B2 Console -> Bucket -> Lifecycle Settings"
    info "This prevents cost accumulation from failed large file uploads"
}

print_summary() {
    echo ""
    echo "=========================================="
    echo "  SUMMARY"
    echo "=========================================="
    echo -e "  ${GREEN}Passed:${NC}   $PASS"
    echo -e "  ${RED}Failed:${NC}   $FAIL"
    echo -e "  ${YELLOW}Warnings:${NC} $WARN"
    echo ""
    
    if [[ $FAIL -gt 0 ]]; then
        echo -e "${RED}Some checks failed. Fix issues before running backups.${NC}"
        return 1
    elif [[ $WARN -gt 0 ]]; then
        echo -e "${YELLOW}All critical checks passed, but there are warnings.${NC}"
        return 0
    else
        echo -e "${GREEN}All checks passed! Ready for backups.${NC}"
        return 0
    fi
}

main() {
    echo "=========================================="
    echo "  PVE B2 Age Backup - Pre-flight Check"
    echo "=========================================="
    
    check_dependencies
    check_config_file
    check_rclone_config
    check_age_keys
    check_staging_space
    check_hook_script
    check_systemd_timers
    check_b2_recommendations
    
    print_summary
}

main "$@"
