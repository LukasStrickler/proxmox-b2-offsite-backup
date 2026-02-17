# Configuration Guide

Reference for all options in `config.env`. After installation, edit `/etc/pve-b2-age-backup/config.env` to set your bucket, paths, and retention.

## Configuration File

- **Location**: `/etc/pve-b2-age-backup/config.env`
- **Template**: `.env.example` (in repository)
- **Format**: Bash environment variables (`KEY="Value"`)

## Quick Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RCLONE_REMOTE` | **Yes** | - | B2 remote and bucket (e.g., `b2:MY_BUCKET`) |
| `DUMPDIR` | **Yes** | `/backup/vzdump` | Local staging for Proxmox backups |
| `AGE_RECIPIENTS` | **Yes** | `/etc.../recipients.txt` | File with public keys for encryption |
| `AGE_IDENTITY` | **Yes** | `/etc.../age.key` | Private key (restore only) |
| `REMOTE_PREFIX` | No | `proxmox` | Subfolder in B2 bucket |
| `HOST` | No | `hostname -s` | Hostname segment in remote path |
| `ALLOW_CONCURRENT_STAGING` | No | `false` | Allow multiple backup files in DUMPDIR (see staging note) |
| `KEEP_DAILY` | No | `7` | Days to keep |
| `RCAT_CUTOFF` | No | `8M` | Upload buffer size |

---

## Required Settings

### RCLONE_REMOTE
The rclone remote and bucket name where backups will be stored.

```bash
RCLONE_REMOTE="b2:MY_BACKUP_BUCKET"
```
- **Format**: `REMOTE_NAME:BUCKET_NAME`
- **Note**: Ensure `rclone config` is run first to create the remote.

### DUMPDIR
**Staging directory**: Proxmox writes the backup file here; the hook then encrypts it, uploads to B2, and deletes the local file. So you need enough space for one full backup (largest VM + 10%).

```bash
DUMPDIR="/backup/vzdump"
```
- **Requirements**:
  - Must be a valid Proxmox storage location (Directory type).
  - Must have enough free space for your largest VM + 10%.
- **Recommendation**: Use a separate dataset or disk (e.g., ZFS dataset with quota).

### AGE_RECIPIENTS
Path to the file containing age public keys. Used for **encryption**.

```bash
AGE_RECIPIENTS="/etc/pve-b2-age-backup/recipients.txt"
```
- **Format**: One age public key per line (starts with `age1...`).
- **Security**: World-readable (644) is fine, but write-protected.

### AGE_IDENTITY
Path to the age private key identity file. Used ONLY for **restore** and **verify**.

```bash
AGE_IDENTITY="/etc/pve-b2-age-backup/age.key"
```
- **Security**: MUST be permission 600 (read/write by root only).
- **Production Tip**: For maximum security, do not store this file on the backup server unless actively restoring.
- **At install/setup**: Download and securely store `age.key` (and `recipients.txt`) to an offline, safe location. Without the private key you cannot restore backups or get them working again.

---

## Optional Settings

### Remote Paths

#### REMOTE_PREFIX
Top-level directory inside your B2 bucket.
```bash
REMOTE_PREFIX="proxmox"
```
- **Result**: `b2:BUCKET/{REMOTE_PREFIX}/{HOSTNAME}/...`

#### HOST
Override the hostname used in the remote path.
```bash
HOST="pve-node-01"
```
- **Default**: Output of `hostname -s`
- **Use Case**: Cluster migrations or consistent naming if hostname changes.

#### ALLOW_CONCURRENT_STAGING
Allow more than one backup file in `DUMPDIR` at a time (default: `false`).
```bash
# ALLOW_CONCURRENT_STAGING=true   # Only if staging is large enough
```
- **Default**: `false` — the hook fails **backup-start** if any other backup file is already in `DUMPDIR`. This enforces **one backup at a time**: space is only freed after upload in **backup-end**, so with limited staging (e.g. 100GB) you must not start the next job until the previous one has finished and the hook has deleted the local file.
- **Set to `true`** only if your staging is large enough to hold multiple full backups (e.g. 500GB for several 80GB VMs). Otherwise overlapping jobs will fill the disk.

### Retention Policy

Controls how many backups are kept on B2. Pruning runs daily via `pve-b2-age-prune.service`.

```bash
KEEP_DAILY=7        # Keep 7 most recent daily backups
KEEP_MONTHLY=1      # Keep 1 most recent monthly backup
KEEP_LOGS=30        # Keep 30 most recent log files
ENABLE_MONTHLY=true # Create monthly copy on day 01
```

- **ENABLE_MONTHLY**: If `true`, on the 1st of the month, the daily backup is server-side copied to the `monthly/` folder.

### Performance

```bash
RCAT_CUTOFF="8M"
UPLOAD_ATTEMPTS=6
BASE_BACKOFF=20
```

- **RCAT_CUTOFF**: Rclone streaming buffer. Higher values (e.g., `128M`) use more RAM but reduce API calls.
- **UPLOAD_ATTEMPTS**: Number of retries if upload fails.
- **BASE_BACKOFF**: Base seconds for exponential backoff (20s, 40s, 80s...).

### Verification

```bash
VERIFY_HASH=true
```
- **true**: Calculates SHA256 of downloaded file during restore and compares with manifest. Slower but safer.
- **false**: Skips hash check.

### Work Directories

Directories used for temporary file operations.

```bash
# For restores (needs space for full backup)
RESTORE_WORKDIR="/var/lib/vz/dump"

# For verification downloads
VERIFY_WORKDIR="/var/tmp"

# For host config backup generation
WORKDIR="/var/tmp"
```

- **RESTORE_WORKDIR**: Where decrypted `.vma.zst` files are placed for Proxmox to restore.
- **WORKDIR**: Used by `pve-b2-age-hostconfig.sh` to assemble `/etc` backups.

### Logging

```bash
LOG="/var/log/pve-b2-age.log"
```
- Main log file for hook and scripts.
- Log rotation is handled by system logrotate (if installed via install script).

---

## Advanced Rclone Config

While `config.env` handles the script options, rclone itself has performance tunables in `/root/.config/rclone/rclone.conf`:

```ini
[b2]
type = b2
account = ...
key = ...
hard_delete = false
chunk_size = 96M
upload_cutoff = 200M
upload_concurrency = 4
```

- **hard_delete = false**: (Recommended) Soft-delete files in B2 (hide) instead of permanent erase, allowing recovery of accidental deletions via B2 interface.
- **chunk_size**: Larger chunks improve upload stability for large files.

## Environment Overrides

You can override any setting per-command:

```bash
# List backups from a different bucket
RCLONE_REMOTE="b2:ARCHIVE_BUCKET" pve-b2-age-list.sh

# Use a different config file entirely
CONFIG_FILE="/etc/pve-b2-age-backup/dev.env" pve-b2-age-check.sh
```
