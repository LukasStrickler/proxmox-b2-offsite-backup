#!/bin/bash
set -euo pipefail

# PVE B2 Age Backup - One-Line Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/LukasStrickler/proxmox-b2-offsite-backup/main/install.sh | sudo bash
# Repository: https://github.com/LukasStrickler/proxmox-b2-offsite-backup

REPO_URL="https://github.com/LukasStrickler/proxmox-b2-offsite-backup"
REPO_RAW="https://raw.githubusercontent.com/LukasStrickler/proxmox-b2-offsite-backup/main"
INSTALL_DIR="/opt/pve-b2-age-backup"
CONFIG_DIR="/etc/pve-b2-age-backup"
BIN_DIR="/usr/local/sbin"
SYSTEMD_DIR="/etc/systemd/system"
LOG_FILE="/var/log/pve-b2-age-install.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; }
fail() { error "$*"; exit 1; }

# Print banner
print_banner() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   PVE B2 Age Backup - Encrypted Off-site Backup Solution      ║
║                                                               ║
║   Repository: https://github.com/LukasStrickler/              ║
║               proxmox-b2-offsite-backup                       ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        fail "This script must be run as root. Use: sudo bash $0"
    fi
    log "Running as root: OK"
}

# Check Proxmox VE
check_proxmox() {
    if [[ ! -f /etc/pve/pve.cfg ]]; then
        error "This doesn't appear to be a Proxmox VE server"
        error "Missing: /etc/pve/pve.cfg"
        error ""
        error "This backup solution is designed specifically for Proxmox VE."
        read -rp "Continue anyway? [y/N]: " response
        [[ "$response" =~ ^[Yy]$ ]] || exit 1
    else
        log "Proxmox VE detected: OK"
        PVE_VERSION=$(pveversion | head -1)
        info "Version: $PVE_VERSION"
    fi
}

# Check and install dependencies
check_disk_space() {
    local required_gb=10
    local available_kb
    available_kb=$(df -k /usr 2>/dev/null | awk 'NR==2 {print $4}')
    
    if [[ -n "$available_kb" ]]; then
        local available_gb=$((available_kb / 1024 / 1024))
        if (( available_gb < required_gb )); then
            warn "Low disk space: ${available_gb}GB available, ${required_gb}GB recommended for staging"
        else
            log "Disk space: OK (${available_gb}GB available)"
        fi
    fi
}

check_network() {
    if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        warn "No network connectivity detected - B2 upload will fail"
    else
        log "Network connectivity: OK"
    fi
}

check_dependencies() {
    info "Checking dependencies..."
    
    local missing=()
    local deps=("rclone" "age" "jq" "curl" "zstd")

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        else
            local version
            case "$dep" in
                rclone) version=$(rclone --version 2>&1 | head -1) ;;
                age) version=$(age --version 2>&1 || echo "installed") ;;
                jq) version=$(jq --version 2>&1) ;;
                zstd) version=$(zstd --version 2>&1 | head -1 || echo "installed") ;;
                *) version="installed" ;;
            esac
            log "  ✓ $dep: $version"
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing dependencies: ${missing[*]}"
        info "Installing missing dependencies..."
        
        apt-get update -qq
        apt-get install -y "${missing[@]}"
        
        info "Dependencies installed"
    else
        log "All dependencies satisfied"
    fi
}

# Download scripts
download_scripts() {
    info "Downloading scripts..."
    
    mkdir -p "$INSTALL_DIR/scripts"
    mkdir -p "$INSTALL_DIR/systemd"
    mkdir -p "$INSTALL_DIR/lib"
    
    local scripts=(
        "scripts/pve-b2-age-hook.sh"
        "scripts/pve-b2-age-prune.sh"
        "scripts/pve-b2-age-restore.sh"
        "scripts/pve-b2-age-restore-hostconfig.sh"
        "scripts/pve-b2-age-list.sh"
        "scripts/pve-b2-age-verify.sh"
        "scripts/pve-b2-age-hostconfig.sh"
        "scripts/pve-b2-age-check.sh"
    )
    
    for script in "${scripts[@]}"; do
        local filename
        filename=$(basename "$script")
        info "  Downloading: $filename"
        curl -fsSL "${REPO_RAW}/${script}" -o "${INSTALL_DIR}/${script}"
        chmod 700 "${INSTALL_DIR}/${script}"
    done
    
    info "  Downloading: lib/common.sh"
    curl -fsSL "${REPO_RAW}/lib/common.sh" -o "${INSTALL_DIR}/lib/common.sh"
    
    local units=(
        "systemd/pve-b2-age-prune.service"
        "systemd/pve-b2-age-prune.timer"
        "systemd/pve-b2-age-hostconfig.service"
        "systemd/pve-b2-age-hostconfig.timer"
    )
    
    for unit in "${units[@]}"; do
        local filename
        filename=$(basename "$unit")
        info "  Downloading: $filename"
        curl -fsSL "${REPO_RAW}/${unit}" -o "${INSTALL_DIR}/${unit}"
    done
    
    info "  Downloading: .env.example"
    curl -fsSL "${REPO_RAW}/.env.example" -o "${INSTALL_DIR}/.env.example"
    
    log "All files downloaded to $INSTALL_DIR"
}

# Install scripts to system
install_scripts() {
    info "Installing scripts to $BIN_DIR..."
    
    for script in "$INSTALL_DIR"/scripts/*.sh; do
        local filename=$(basename "$script")
        install -m 700 "$script" "${BIN_DIR}/${filename}"
        log "  Installed: $filename"
    done
    
    info "Installing shared library..."
    mkdir -p /usr/local/lib/pve-b2-age
    install -m 644 "$INSTALL_DIR/lib/common.sh" /usr/local/lib/pve-b2-age/common.sh
    log "  Installed: /usr/local/lib/pve-b2-age/common.sh"
}

# Install systemd units
install_systemd() {
    info "Installing systemd units..."
    
    for unit in "$INSTALL_DIR"/systemd/*.{service,timer}; do
        [[ -f "$unit" ]] || continue
        local filename=$(basename "$unit")
        install -m 644 "$unit" "${SYSTEMD_DIR}/${filename}"
        log "  Installed: $filename"
    done
    
    systemctl daemon-reload
    log "Systemd daemon reloaded"
}

# Setup configuration directory
setup_config() {
    info "Setting up configuration..."
    
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    
    if [[ ! -f "${CONFIG_DIR}/config.env" ]]; then
        info "Creating initial configuration"
        install -m 600 "$INSTALL_DIR/.env.example" "${CONFIG_DIR}/config.env"
        log "  Created: ${CONFIG_DIR}/config.env"
        CONFIG_CREATED=true
    else
        log "Configuration already exists: ${CONFIG_DIR}/config.env"
        warn "Review for new options: diff ${CONFIG_DIR}/config.env ${INSTALL_DIR}/.env.example"
        CONFIG_CREATED=false
    fi
}

# Generate age keys
generate_age_key() {
    local key_file="${CONFIG_DIR}/age.key"
    local recipients_file="${CONFIG_DIR}/recipients.txt"
    
    if [[ -f "$key_file" ]]; then
        log "Age key already exists: $key_file"
        return 0
    fi
    
    info ""
    info "=== Age Key Generation ==="
    info ""
    info "Age encryption keys are required for backup encryption."
    info ""
    info "  - Private key: $key_file (KEEP SECURE - needed for restore)"
    info "  - Public key:  $recipients_file (used for encryption)"
    info ""
    read -rp "Generate age key now? [Y/n]: " response
    
    if [[ -z "$response" || "$response" =~ ^[Yy]$ ]]; then
        info "Generating age key..."
        age-keygen -o "$key_file" 2>&1 | tee -a "$LOG_FILE"
        chmod 600 "$key_file"
        
        grep -oE 'age1[0-9a-z]+' "$key_file" > "$recipients_file"
        chmod 600 "$recipients_file"
        
        info ""
        log "Age key generated successfully!"
        log "  Private key: $key_file"
        log "  Public key:  $recipients_file"
        info ""
        warn "CRITICAL: DOWNLOAD AND SECURELY STORE your encryption keys now!"
        warn "  - Copy $key_file (private key) and $recipients_file (public key) to a safe place."
        warn "  - Store offline (e.g. encrypted USB, password manager, safe)."
        warn "  - Without the private key you CANNOT restore your backups or get them working again."
    else
        warn "Skipping age key generation"
        warn "You must manually create ${CONFIG_DIR}/recipients.txt with your public key(s)"
    fi
}

# Print next steps
print_next_steps() {
    cat << EOF

${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}
${GREEN}║                    INSTALLATION COMPLETE                      ║${NC}
${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}

${BLUE}Next Steps:${NC}

${RED}0. DOWNLOAD AND SECURELY STORE your encryption keys (REQUIRED):${NC}
   - Copy these files off this host to a safe, offline location (e.g. encrypted USB, password manager):
     ${CONFIG_DIR}/age.key          (private key - without it you CANNOT restore backups)
     ${CONFIG_DIR}/recipients.txt   (public key(s) - needed to re-create setup)
   - Without the private key, you cannot get your backups working again after a disaster.

${YELLOW}1. Configure the backup system:${NC}
   sudo nano /etc/pve-b2-age-backup/config.env

   Required settings:
   - RCLONE_REMOTE: Your rclone remote (e.g., "b2:MY_BUCKET")
   - DUMPDIR: Local staging directory for backups
   - AGE_RECIPIENTS: Path to age public keys file

${YELLOW}2. Configure rclone for Backblaze B2:${NC}
   sudo rclone config

   Create a new remote:
   - Name: b2 (or match your RCLONE_REMOTE setting)
   - Type: b2
   - Account: Your B2 Key ID
   - Key: Your B2 Application Key

${YELLOW}3. Set up Proxmox storage for local staging:${NC}
   - Datacenter -> Storage -> Add -> Directory
   - Path: /backup/vzdump (or your DUMPDIR)
   - Content: VZDump backup file

${YELLOW}4. Create backup jobs in Proxmox:${NC}
   - Create ONE job per VM (not "All")
   - Set the hook script: /usr/local/sbin/pve-b2-age-hook.sh

${YELLOW}5. Enable automatic pruning:${NC}
   sudo systemctl enable --now pve-b2-age-prune.timer

${YELLOW}6. Enable host config backups:${NC}
   sudo systemctl enable --now pve-b2-age-hostconfig.timer

${YELLOW}7. Test your setup:${NC}
   - Run a manual backup job
   - Check logs: sudo tail -f /var/log/pve-b2-age.log
   - List backups: sudo pve-b2-age-list.sh

${YELLOW}8. Validate your setup:${NC}
   sudo pve-b2-age-check.sh

${BLUE}Documentation:${NC}
  - README: https://github.com/LukasStrickler/proxmox-b2-offsite-backup
  - Quick Start: ${REPO_URL}/blob/main/docs/guides/quickstart.md
  - Configuration: ${REPO_URL}/blob/main/docs/guides/configuration.md

${BLUE}Support:${NC}
  - Issues: ${REPO_URL}/issues
  - Discussions: ${REPO_URL}/discussions

EOF
}

# Print install summary
print_summary() {
    info ""
    info "=== Installation Summary ==="
    info "  Install directory: $INSTALL_DIR"
    info "  Config directory:  $CONFIG_DIR"
    info "  Scripts installed: $BIN_DIR"
    info "  Systemd units:     $SYSTEMD_DIR"
    info ""
    
    if [[ "${CONFIG_CREATED:-false}" == "true" ]]; then
        warn "Configuration file created but needs to be customized!"
        warn "Run: sudo nano $CONFIG_DIR/config.env"
    fi
}

# Main installation flow
main() {
    # Initialize log
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== PVE B2 Age Backup Installation ===" > "$LOG_FILE"
    echo "Date: $(date)" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    
    print_banner
    echo ""
    
    check_root
    check_proxmox
    check_disk_space
    check_network
    check_dependencies
    
    download_scripts
    install_scripts
    install_systemd
    setup_config
    generate_age_key
    
    print_summary
    print_next_steps
}

# Run main function
main "$@"
