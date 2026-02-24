# Restore Operations Guide

How to restore VMs, containers, and host configuration from your encrypted B2 backups. In short: list backups with `pve-b2-age-list.sh`, choose a file, then run `pve-b2-age-restore.sh` with that filename and a new VM/CT ID.

## Prerequisites

- **Age Private Key** (`age.key`): Required for decryption. You must have downloaded and securely stored this (and optionally `recipients.txt`) at install time; without it, restores are impossible.
- **Local Storage**: Sufficient space for the decrypted backup file.
- **B2 Access**: Rclone configured with read access to the bucket.
- **Target VMID**: Must not already exist on the host.

## Quick Reference

| Action | Command |
|--------|---------|
| **List Backups** | `sudo pve-b2-age-list.sh -v daily` (or `monthly`, `all`, `hostconfig`) |
| **Restore VM/CT** | `sudo pve-b2-age-restore.sh TIER FILE NEW_VMID` |
| **Restore Host Config** | `sudo pve-b2-age-restore-hostconfig.sh [--extract-to DIR]` |
| **Verify Backup** | `sudo pve-b2-age-verify.sh TIER FILE` |

## Standard Restore (VM & LXC)

The `pve-b2-age-restore.sh` script handles downloading, decrypting, verifying, and restoring automatically.

### Basic Restore

Restore a VM or Container to a new ID:

```bash
# Syntax: pve-b2-age-restore.sh TIER FILENAME NEW_VMID [STORAGE_ID]

# Example: Restore VM 101 from daily backup to new VM 201
sudo pve-b2-age-restore.sh daily \
  vzdump-qemu-101-2026_02_15-02_00_01.vma.zst.age \
  201

# Example: Restore Container 102 from monthly backup to new CT 202
sudo pve-b2-age-restore.sh monthly \
  vzdump-lxc-102-2026_02_01-04_00_01.tar.zst.age \
  202
```

### Restore to Specific Storage

Specify a target storage ID (e.g., `local-zfs`, `ceph`):

```bash
sudo pve-b2-age-restore.sh daily \
  vzdump-qemu-101-2026_02_15-02_00_01.vma.zst.age \
  201 \
  local-zfs
```

### Post-Restore Steps

1. **Verify**: Check hardware settings and network config in Proxmox UI.
2. **Start**: `sudo qm start 201` (VM) or `sudo pct start 202` (CT).
3. **Cleanup**: The script keeps the decrypted backup in `RESTORE_WORKDIR` for verification. Remove it manually when done: `rm /var/lib/vz/dump/<filename>`.

## Verification

Validate a backup's integrity without restoring it.

```bash
# Verify integrity (downloads, decrypts, checks hash)
sudo pve-b2-age-verify.sh daily vzdump-qemu-101-....age

# Verify and delete decrypted artifact immediately
sudo pve-b2-age-verify.sh --delete daily vzdump-qemu-101-....age
```

## Advanced Scenarios

### Restoring Host Configuration

Recover `/etc`, `/var/lib/pve-cluster`, and `/root` from hostconfig backups. Use the dedicated script (recommended) or manual steps.

**Option A — Script (recommended):**

```bash
# List available hostconfig backups
sudo pve-b2-age-list.sh hostconfig

# Restore latest backup (decrypt only; file is left in WORKDIR)
sudo pve-b2-age-restore-hostconfig.sh

# Restore specific file and extract to a directory
sudo pve-b2-age-restore-hostconfig.sh --extract-to /tmp/restore-host \
  pve-hostcfg-pve1-2026_02_17-12_00_00.tar.zst.age

# Extract specific files after restore
tar -xaf /var/tmp/pve-hostcfg-*.tar.zst -C /tmp/restore-host etc/network/interfaces
```

**Option B — Manual:** Download with rclone, decrypt with age, then extract with tar. See [Disaster Recovery](../workflows/disaster-recovery.md) for full steps.

### Cross-Host Restore

Restore a backup created on `SOURCE_HOST` to `TARGET_HOST`.

1.  **Ensure Keys Match**: `TARGET_HOST` must have the `age.key` used to encrypt the backup.
2.  **Locate Backup**:
    ```bash
    sudo pve-b2-age-list.sh --host SOURCE_HOST daily
    ```
3.  **Manual Download & Restore**:
    ```bash
    # Download
    sudo rclone copyto b2:BUCKET/proxmox/SOURCE_HOST/daily/BACKUP_FILENAME.age /var/lib/vz/dump/backup.age
    
    # Restore using local file
    sudo age -d -i /etc/pve-b2-age-backup/age.key -o /var/lib/vz/dump/backup.vma.zst /var/lib/vz/dump/backup.age
    sudo qmrestore /var/lib/vz/dump/backup.vma.zst 201
    ```

### Single File Restore

Extract a specific file from a backup without a full VM/CT restore.

```bash
# 1. Download and decrypt backup manually:
#    rclone copyto b2:BUCKET/.../backup.age /tmp/backup.age
#    age -d -i /etc/pve-b2-age-backup/age.key -o /tmp/backup.vma.zst /tmp/backup.age

# 2. Extract file from VM backup (VMA format; requires zstd, vma, and libguestfs-tools)
zstd -d -o /tmp/backup.vma /tmp/backup.vma.zst
mkdir -p /tmp/vma-extract /tmp/recovered
vma extract /tmp/backup.vma /tmp/vma-extract
# Select the extracted disk image (example: drive-scsi0.raw)
virt-copy-out -a /tmp/vma-extract/drive-scsi0.raw /etc/passwd /tmp/recovered/

# 3. Extract file from container backup (tar)
tar -xaf /tmp/backup.tar.zst -C /tmp/recovered ./etc/passwd
```

## Manual Restore Process (Fallback)

If scripts are unavailable, perform a manual restore:

1.  **Download**: `rclone copyto b2:BUCKET/path/backup.age local.age`
2.  **Download Manifest**: `rclone copyto b2:BUCKET/path/manifest.json.age manifest.json.age`
3.  **Decrypt**:
    ```bash
    age -d -i age.key -o backup.vma.zst local.age
    age -d -i age.key -o manifest.json manifest.json.age
    ```
4.  **Verify**: Check file size against `size_bytes` in manifest.
5.  **Restore**:
    ```bash
    qmrestore BACKUP_FILE.vma.zst VMID      # for VMs
    pct restore VMID BACKUP_FILE.tar.zst    # for CTs
    ```

## Troubleshooting

For common errors ("Decryption failed", "Size mismatch", "VMID exists"), see:
**[Troubleshooting Common Issues](../troubleshooting/common-issues.md)**

## Best Practices

1.  **Test Regularly**: Perform test restores monthly to verify keys and data integrity.
2.  **Keep Keys Safe**: At install/setup, download and securely store `age.key` and `recipients.txt` offline (e.g. encrypted USB, password manager). Without the private key you cannot restore backups or get them working again.
3.  **Verify First**: Use `pve-b2-age-verify.sh` on critical backups before needing them.
