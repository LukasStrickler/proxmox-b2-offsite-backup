# Disaster Recovery Workflow

Complete procedures for recovering from catastrophic failures using PVE B2 Age Backup.

## 1. Disaster Scenarios & Objectives

| Scenario | Impact | Est. Recovery | Procedure |
|----------|--------|---------------|-----------|
| **Single VM Failure** | One VM corrupted/deleted | 15-60 min | Restore specific VM from backup |
| **Host Hardware Failure** | Node down | 2-8 hours | Rebuild host, restore all VMs |
| **Storage Failure** | Local data lost | 4-24 hours | Replace storage, restore from B2 |
| **Ransomware** | Data encrypted | 4-24 hours | Rebuild, restore from *clean* B2 backups |
| **Site Loss** | Datacenter destroyed | 1-3 days | Build new infra, full restore |

## 2. Pre-Recovery Prerequisites

**Emergency Kit (Offline USB)**  
You must have **downloaded and securely stored** these at install/setup. Without the private key, you cannot restore backups or get them working again.

Ensure you have access to:
*   `age.key`: Private encryption key (Critical)
*   `recipients.txt`: Public key(s) (needed to re-create config)
*   `b2-credentials.txt`: Bucket name, Key ID, App Key
*   `vm-inventory.txt`: List of VMs/IPs (optional but helpful)
*   System root passwords

## 3. Phase 1: Infrastructure Rebuild

*Skip this phase if the Proxmox host is still operational.*

### 1.1 Base System Setup
1.  **Install Proxmox VE** on new hardware.
2.  **Configure Network** (`/etc/network/interfaces`) to match the original host if possible.
3.  **Update System**:
    ```bash
    apt update && apt upgrade -y
    hostnamectl set-hostname pve-recovery-01
    reboot
    ```

### 1.2 Install Backup Tools
```bash
# Install dependencies
apt install -y rclone age jq curl git zstd

# Verify installation
rclone --version && age --version
```

### 1.3 Storage Setup
Ensure your restoration target storage exists (e.g., ZFS pool or directory).
```bash
# Example: Create ZFS pool and dataset
zpool create -f rpool mirror /dev/sda /dev/sdb
zfs create rpool/data
zfs create -o mountpoint=/backup/vzdump rpool/backup-vzdump

# Add to Proxmox Storage Configuration
pvesh create /storage --storage backup-vzdump --type dir --path /backup/vzdump --content backup
```

## 4. Phase 2: Backup System Restoration

### 2.1 Re-Install Tooling
```bash
cd /opt
git clone https://github.com/LukasStrickler/proxmox-b2-offsite-backup.git
cd proxmox-b2-offsite-backup
./install.sh
```

### 2.2 Configure Access & Encryption
1.  **Configure B2 Remote**:
    ```bash
    rclone config
    # Name: b2, Type: b2, Account: KEY_ID, Key: APP_KEY
    rclone lsf b2:YOUR_BUCKET_NAME  # Verify access
    ```

2.  **Restore Private Key**:
    *   *From USB/Secure Storage*: `cp /mnt/usb/age.key /etc/pve-b2-age-backup/`
    
    > ⚠️ **Security Note**: Do NOT store your private age key in B2. Storing the decryption key alongside encrypted backups defeats the purpose of encryption. Keep your private key offline in a secure location (encrypted USB, password manager, or hardware security module).
    
    *   **Secure Permissions**: `chmod 600 /etc/pve-b2-age-backup/age.key`

3.  **Configure Environment**:
    Edit `/etc/pve-b2-age-backup/config.env`:
    ```bash
    RCLONE_REMOTE="b2:YOUR_BUCKET_NAME"
    DUMPDIR="/backup/vzdump"
    AGE_IDENTITY="/etc/pve-b2-age-backup/age.key"
    ```

## 5. Phase 3: Host Configuration Restore (Optional)

**⚠️ Warning**: Only restore host config to a fresh install to avoid conflicts.

**Option A — Script (recommended):**

```bash
# List backups (use --host OLD_HOSTNAME if restoring from another host)
sudo pve-b2-age-list.sh --host OLD_HOSTNAME hostconfig

# Restore latest and extract to a directory
sudo pve-b2-age-restore-hostconfig.sh --host OLD_HOSTNAME --extract-to /tmp/hostcfg-restore

# Copy only the files you need (e.g. network, storage)
sudo cp -a /tmp/hostcfg-restore/etc/network/interfaces /etc/network/
sudo cp -a /tmp/hostcfg-restore/etc/pve/storage.cfg /etc/pve/  # if applicable
sudo systemctl restart networking pvedaemon pveproxy
```

**Option B — Manual:**

```bash
# 1. List backups to get the exact filename (they are timestamped)
rclone lsf b2:YOUR_BUCKET_NAME/proxmox/OLD_HOSTNAME/hostconfig/

# 2. Download and decrypt (replace ENCRYPTED_FILENAME with the chosen .age file)
rclone copyto b2:YOUR_BUCKET_NAME/proxmox/OLD_HOSTNAME/hostconfig/ENCRYPTED_FILENAME.age /tmp/hostcfg.tar.zst.age
age -d -i /etc/pve-b2-age-backup/age.key -o /tmp/hostcfg.tar.zst /tmp/hostcfg.tar.zst.age

# 3. Extract specific configs (recommended — do not blindly overwrite /)
tar -xvf /tmp/hostcfg.tar.zst -C /tmp/restore etc/network/interfaces etc/pve/storage.cfg
# Then copy what you need into / and restart services
```

## 6. Phase 4: Virtual Machine Restoration

### 4.1 Inventory & Planning
Identify which backups to restore.
```bash
# List all available backups
pve-b2-age-list.sh all

# Generate JSON inventory for parsing
pve-b2-age-list.sh -j all > /tmp/inventory.json
```

### 4.2 Priority 1: Critical Infrastructure
Restore DNS, Identity, and Networking first.
```bash
# Syntax: pve-b2-age-restore.sh TIER FILE NEW_VMID
pve-b2-age-restore.sh daily BACKUP_FILENAME.age 100
pve-b2-age-restore.sh daily BACKUP_FILENAME.age 101
```

### 4.3 Priority 2: Production Services (Batch Restore)
For restoring multiple VMs efficiently, use a loop instead of manual commands.

```bash
#!/bin/bash
# Batch Restore Loop
# Usage: Define list of "BACKUP_FILE:VMID"

BACKUPS=(
    "vzdump-qemu-102-....vma.zst.age:102"
    "vzdump-qemu-103-....vma.zst.age:103"
    "vzdump-qemu-104-....vma.zst.age:104"
)

for item in "${BACKUPS[@]}"; do
    IFS=':' read -r file vmid <<< "$item"
    echo "Starting restore of VM $vmid..."
    if pve-b2-age-restore.sh daily "$file" "$vmid"; then
        echo "✅ VM $vmid restored successfully."
    else
        echo "❌ VM $vmid failed to restore."
    fi
done
```

### 4.4 Restore Containers (LXC)
The process is identical for containers.
```bash
pve-b2-age-restore.sh daily BACKUP_FILENAME.age 200
```

## 7. Phase 5: Validation & Post-Recovery

### 5.1 Verification Checklist
- [ ] **VM Count**: `qm list | wc -l` matches inventory.
- [ ] **Power On**: Ensure all VMs boot (`qm start VMID`).
- [ ] **Connectivity**: Ping test critical IPs.
- [ ] **Services**: Verify application health (HTTP, SQL, etc.).

### 5.2 Re-Enable Backups
Once the system is stable, re-enable the backup schedule.
1.  **Recreate Backup Jobs** in Proxmox UI (Datacenter -> Backup).
    *   *Important*: Re-attach the hook script `/usr/local/sbin/pve-b2-age-hook.sh`.
2.  **Enable Maintenance Timers**:
    ```bash
    systemctl enable --now pve-b2-age-prune.timer
    systemctl enable --now pve-b2-age-hostconfig.timer
    ```
3.  **Test Backup**: Run a manual backup of a non-critical VM to verify upload.

## 8. Specialized Procedures

### Ransomware Response
1.  **Isolate**: Disconnect network immediately.
2.  **Preserve B2**: **DO NOT** delete anything from B2. Your immutable/hidden versions might be needed.
3.  **Clean Install**: Do not trust the infected OS. Reinstall Proxmox from ISO.
4.  **Verify Backup**: Restore a VM to an isolated network. Check for encryption/ransom notes before reconnecting to production.
    ```bash
    # Verify hash before restore
    pve-b2-age-verify.sh daily BACKUP_FILE
    ```

### Single File Recovery
To recover a config file without restoring the whole VM:
1.  **Download and decrypt** (or use `pve-b2-age-restore.sh` and stop before qmrestore):
    ```bash
    rclone copyto b2:BUCKET/.../backup.age /tmp/backup.age
    age -d -i /etc/pve-b2-age-backup/age.key -o /tmp/backup.vma.zst /tmp/backup.age
    zstd -d -o /tmp/backup.vma /tmp/backup.vma.zst
    ```
2.  **Extract file** (requires `libguestfs-tools`):
    ```bash
    virt-copy-out -a /tmp/backup.vma /etc/important.conf /tmp/recovered/
    ```

## 9. Emergency Contacts

| Role | Name | Phone/Email |
|------|------|-------------|
| **Primary Admin** | ________________ | ________________ |
| **Secondary** | ________________ | ________________ |
| **Network/ISP** | ________________ | ________________ |
| **Hardware Support** | ________________ | ________________ |

## 10. Post-Mortem
After recovery is complete:
1.  Document the incident timestamp and root cause.
2.  List data loss (if any) based on RPO.
3.  Rotate `age` keys if the private key was exposed:
    *   Generate new key: `age-keygen -o age-new.key`
    *   Update `recipients.txt` on all nodes.
    *   Update `config.env`.

---
**Related Docs**: [Restore Guide](../guides/restore-operations.md) | [Backup Guide](../guides/backup-operations.md) | [Troubleshooting](../troubleshooting/common-issues.md)
