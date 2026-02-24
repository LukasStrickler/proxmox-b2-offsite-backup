#!/usr/bin/env bash
set -euo pipefail

# PVE B2 Age Backup - Uninstaller
# Removes all installed files and optionally configuration
# Usage: sudo bash uninstall.sh (or chmod +x uninstall.sh && sudo ./uninstall.sh)

INSTALL_DIR="/opt/pve-b2-age-backup"
CONFIG_DIR="/etc/pve-b2-age-backup"
BIN_DIR="/usr/local/sbin"
LIB_DIR="/usr/local/lib/pve-b2-age"
SYSTEMD_DIR="/etc/systemd/system"
LOG_FILE="/var/log/pve-b2-age-install.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root. Use: sudo bash $0"
    exit 1
fi

echo ""
echo "This will remove PVE B2 Age Backup from your system."
echo ""
echo "Files to be removed:"
echo "  - Scripts in $BIN_DIR"
echo "  - Library in $LIB_DIR"
echo "  - Systemd units in $SYSTEMD_DIR"
echo "  - Install directory $INSTALL_DIR"
echo ""
echo -e "${YELLOW}Configuration in $CONFIG_DIR will be preserved.${NC}"
echo -e "${YELLOW}Backups in B2 are NOT affected.${NC}"
echo ""
read -rp "Continue with uninstall? [y/N]: " response
[[ "$response" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Stop and disable timers
log "Stopping systemd timers..."
systemctl stop pve-b2-age-prune.timer 2>/dev/null || true
systemctl stop pve-b2-age-hostconfig.timer 2>/dev/null || true
systemctl disable pve-b2-age-prune.timer 2>/dev/null || true
systemctl disable pve-b2-age-hostconfig.timer 2>/dev/null || true

# Remove systemd units
log "Removing systemd units..."
rm -f "$SYSTEMD_DIR"/pve-b2-age-prune.{service,timer}
rm -f "$SYSTEMD_DIR"/pve-b2-age-hostconfig.{service,timer}
systemctl daemon-reload

# Remove scripts
log "Removing scripts..."
rm -f "$BIN_DIR"/pve-b2-age-hook.sh
rm -f "$BIN_DIR"/pve-b2-age-prune.sh
rm -f "$BIN_DIR"/pve-b2-age-restore.sh
rm -f "$BIN_DIR"/pve-b2-age-restore-hostconfig.sh
rm -f "$BIN_DIR"/pve-b2-age-list.sh
rm -f "$BIN_DIR"/pve-b2-age-verify.sh
rm -f "$BIN_DIR"/pve-b2-age-hostconfig.sh
rm -f "$BIN_DIR"/pve-b2-age-check.sh

# Remove library
log "Removing library..."
rm -rf "$LIB_DIR"

# Remove install directory
log "Removing install directory..."
rm -rf "$INSTALL_DIR"

# Remove install log
rm -f "$LOG_FILE"

rm -f /var/log/pve-b2-age.log 2>/dev/null || true
rm -f /var/log/pve-b2-age-restore.log 2>/dev/null || true
rm -f /var/log/pve-b2-age-verify.log 2>/dev/null || true
echo ""
log "Uninstall complete!"
echo ""
warn "Configuration preserved at: $CONFIG_DIR"
warn "To remove configuration (including keys!): rm -rf $CONFIG_DIR"
echo ""
warn "IMPORTANT: Remove the hook script from your Proxmox backup jobs!"
warn "  Datacenter -> Backup -> select each job -> remove Hook script path"
warn "  Otherwise backups will fail with 'script not found' errors."
echo ""
warn "Your backups in B2 are unaffected."
warn "To remove B2 backups, use: rclone purge b2:YOUR_BUCKET/proxmox"
echo ""
