# Troubleshooting Common Issues

Solutions to common problems with PVE B2 Age Backup.

## ⚡ Run the diagnostic first

Run the built-in check. It verifies that required tools are installed, the config file exists and has the right settings, the `rclone` remote is configured, encryption keys are in place, and the hook script is installed.

```bash
sudo pve-b2-age-check.sh
```

If the check passes but issues persist, consult the specific sections below.

---

## 🔧 Installation & Configuration

### "Command not found" or "Dependency missing"
**Problem**: Required packages (`rclone`, `age`, `jq`, `zstd`, `sqlite3`) are not installed.
**Fix**:
```bash
sudo apt update && sudo apt install -y rclone age jq zstd sqlite3
# Verify
which rclone age jq zstd sqlite3
```

### "Configuration file not found" or Permission Denied
**Problem**: Config file is missing or has wrong permissions.
**Fix**:
```bash
# Create config from template (choose one):
# If you have the repo on this machine (from repo root):
sudo cp .env.example /etc/pve-b2-age-backup/config.env

# If you installed via curl (no repo):
sudo curl -fsSL https://raw.githubusercontent.com/LukasStrickler/proxmox-b2-offsite-backup/main/.env.example -o /etc/pve-b2-age-backup/config.env

# Fix permissions (must be 600)
sudo chmod 600 /etc/pve-b2-age-backup/config.env
```
Then edit `config.env` and set at least `RCLONE_REMOTE` and `DUMPDIR`.

### "Age key not found"
**Problem**: Encryption keys (`recipients.txt` or `age.key`) are missing.
**Fix**:
```bash
# Generate keys if completely missing
sudo age-keygen -o /etc/pve-b2-age-backup/age.key
sudo chmod 600 /etc/pve-b2-age-backup/age.key
sudo age-keygen -y /etc/pve-b2-age-backup/age.key > /etc/pve-b2-age-backup/recipients.txt
sudo chmod 644 /etc/pve-b2-age-backup/recipients.txt
```

---

## 💾 Backup Failures

### "Upload failed" (Rclone connection)
**Problem**: Rclone cannot connect to Backblaze B2.
**Common Causes**: Wrong bucket name, expired key, network issues.
**Fix**:
```bash
# Test connection
sudo bash -lc 'source /etc/pve-b2-age-backup/config.env && rclone lsf "$RCLONE_REMOTE"'

# Reconfigure if needed
sudo rclone config
```

### "Manifest upload failed" (Integrity metadata missing)
**Problem**: Backup data upload succeeded, but manifest upload failed. The hook keeps the local plaintext backup file in `DUMPDIR` to avoid data loss.
**Fix**:
1. Verify the encrypted backup object exists in B2 (`daily/` tier for the host).
2. Re-run the backup for that VM/CT to regenerate both backup and manifest.
3. After you confirm a good backup exists remotely, remove the retained local staging file to free space:
   ```bash
   sudo rm -f /backup/vzdump/vzdump-qemu-* /backup/vzdump/vzdump-lxc-*
   ```

### "TARGET/TARFILE missing" (Hook Logic)
**Problem**: The hook script ran, but Proxmox didn't provide a backup file.
**Fix**:
1. Check `/etc/pve/jobs.cfg` to ensure `script: /usr/local/sbin/pve-b2-age-hook.sh` is set.
2. Check Proxmox task logs (`/var/log/pve/tasks/`) for `vzdump` errors *before* the hook ran.
3. Ensure the backup storage has space.
4. If this job targets **Proxmox Backup Server (PBS)** storage, this hook is not compatible because PBS does not provide a local backup file path for encryption/upload.

### "Staging busy" / backup fails at backup-start
**Problem**: Hook logs *"Staging busy — another backup file already in DUMPDIR"*. Staging is sized for one backup at a time; a second job started while the first file was still on disk (upload in progress or leftover).
**Fix**:
1. **Schedule jobs so they do not overlap.** The next job should start only after the previous one has finished (vzdump + upload) and the hook has deleted the local file. E.g. 100GB staging with 8×80GB VMs: start each job 2+ hours apart.
2. **If a leftover file exists** (e.g. previous upload failed), remove it and retry:
   ```bash
   ls -la /backup/vzdump   # or your DUMPDIR
   sudo rm -f /backup/vzdump/vzdump-qemu-* /backup/vzdump/vzdump-lxc-*
   ```
3. **If you have large staging** and want to allow concurrent backups, set `ALLOW_CONCURRENT_STAGING=true` in `/etc/pve-b2-age-backup/config.env` (see [Configuration](../guides/configuration.md)).

### "No space left on device"
**Problem**: Local staging directory (`DUMPDIR`) is full.
**Fix**:
```bash
# Check usage
df -h /backup/vzdump

# Clean old temporary files (only if no upload is in progress)
sudo rm -f /backup/vzdump/vzdump-*

# Check for stuck locks or large core dumps
find /backup/vzdump -type f -size +100M
```

### "Could not acquire lock"
**Problem**: Another backup process is still running or crashed.
**Fix**:
```bash
# Check running process
ps aux | grep pve-b2-age

# If no process is running, remove stale lock
sudo rm -f /run/lock/pve-b2-age-hook.lock
```

---

## ♻️ Restore Failures

### "Decryption failed"
**Problem**: Wrong private key or corrupted file.
**Fix**:
1. **Verify Key**: Ensure `/etc/pve-b2-age-backup/age.key` matches the `recipients.txt` used for encryption.
   ```bash
   age-keygen -y /etc/pve-b2-age-backup/age.key
   ```
2. **Check Header**: Verify the file is actually age-encrypted.
   ```bash
   sudo rclone cat b2:BUCKET/REMOTE_PATH/BACKUP_FILENAME.age | head -c 100
   # Should start with "age-encryption.org"
   ```

### "VMID already exists"
**Problem**: You are trying to restore to a VM ID that is currently in use.
**Fix**:
- **Option A**: Restore to a new ID:
  ```bash
  pve-b2-age-restore.sh daily BACKUP_FILENAME.age 999
  ```
- **Option B**: Destroy the old VM first (DANGEROUS):
  ```bash
  sudo qm destroy 101 --purge
  ```

---

## 🚀 Performance Optimization

### Slow Uploads
**Analysis**:
Check logs for transfer speeds:
```bash
grep "uploading" /var/log/pve-b2-age.log
```
**Optimization**:
- Increase `RCAT_CUTOFF` in `config.env` (e.g., `16M` or `32M`) if RAM permits.
- Use `zstd` compression in Proxmox backup settings (faster than gzip).
- Run backups during off-peak hours.

### High Memory Usage
**Problem**: OOM (Out of Memory) kills the backup process.
**Fix**:
- Reduce `RCAT_CUTOFF` to `4M` in `config.env`.
- Ensure swap is enabled and available.

---

## ☁️ B2 Storage Issues

### "401 Unauthorized" or "Bucket not found" (B2)
**Problem**: Wrong credentials or key permissions. Rclone with B2 requires the **Application Key ID** (not the main B2 Account ID) as the "account" in `rclone config`. For keys restricted to one bucket, Backblaze must have **"Allow List All Bucket Names"** enabled on the key, or rclone gets 401.
**Fix**:
- In Backblaze: Application Keys → edit or create key → enable **Read and Write** for the bucket and **Allow List All Bucket Names**.
- Run `sudo rclone config` and set **Account** to the Application Key ID (not Account ID). Set **Key** to the Application Key secret.
- List buckets: `sudo rclone lsf b2:` to confirm.

### "Bucket not found" (wrong name)
**Problem**: Configured bucket name doesn't match B2.
**Fix**:
- List buckets: `sudo rclone lsf b2:`
- Update `config.env`: `RCLONE_REMOTE="b2:CORRECT_BUCKET_NAME"`

### High Costs
**Analysis**:
- Check retention policies (`KEEP_DAILY`, `KEEP_MONTHLY`).
- Ensure `pve-b2-age-prune.timer` is active and running.
- Check B2 Lifecycle Rules in the Backblaze web UI (should match or be safer than local prune settings).

---

## ⚙️ Rclone Specific Issues

### "Failed to create bucket"
**Problem**: Rclone permissions or configuration error.
**Fix**:
```bash
# Check rclone config
sudo rclone config show b2

# Verify bucket exists
sudo rclone lsf b2:

# Check application key permissions in B2 console
# Must have read/write access to bucket
```

### "Too many requests" (429 errors)
**Problem**: B2 rate limiting.
**Fix**:
- Retry logic usually handles this.
- Increase `BASE_BACKOFF` in `config.env` (e.g., `BASE_BACKOFF=30`).

### List output looks stale right after upload/prune
**Problem**: Object listings may lag briefly behind writes/deletes on B2.
**Fix**:
- Wait 10-60 seconds and re-run `pve-b2-age-list.sh`.
- Treat manifest/hash verification as the source of truth for restore readiness.

### "Signature mismatch" or Auth Errors
**Problem**: B2 credentials invalid or clock skew.
**Fix**:
- Reconfigure rclone: `sudo rclone config` (delete old remote and recreate).
- Generate new application key in B2 console.
- Check system time: `date` (ensure it's accurate).

---

## 🕒 Systemd & Timer Issues

### Timer not running
**Problem**: Scheduled backups or prunes are not happening.
**Fix**:
```bash
# Check timer status
systemctl status pve-b2-age-prune.timer

# Enable if needed
sudo systemctl enable --now pve-b2-age-prune.timer

# Check service logs
journalctl -u pve-b2-age-prune.service -f
```

### "Failed to start prune service"
**Problem**: Script error or permission issue.
**Fix**:
```bash
# Run manually to diagnose
sudo /usr/local/sbin/pve-b2-age-prune.sh --dry-run

# Check permissions
ls -la /usr/local/sbin/pve-b2-age-prune.sh
```

### Missed timer runs
**Problem**: System was down during scheduled time.
**Fix**:
- Persistent timers catch up automatically when the system boots.
- Check logs: `journalctl -u pve-b2-age-prune.service | grep -E "(Started|Finished)"`

---

## 🎣 Hook Script Issues

### Hook not executing
**Problem**: Hook path wrong or permissions.
**Fix**:
```bash
# Verify hook path in Proxmox config
grep script: /etc/pve/jobs.cfg

# Verify file exists and is executable
ls -la /usr/local/sbin/pve-b2-age-hook.sh

# Check for syntax errors
sudo bash -n /usr/local/sbin/pve-b2-age-hook.sh
```

### Hook runs but backup not uploaded
**Problem**: Hook logic error or early exit.
**Fix**:
- Check logs for "TARGET/TARFILE missing" errors.
- Verify the backup job actually created a file (vzdump didn't fail).
- Check `backup-end` phase execution in `/var/log/pve-b2-age.log`.

---

## 🛠️ Advanced Debugging

If `pve-b2-age-check.sh` and the steps above don't solve it, collect full debug info.

### 1. Enable Verbose Logging
Edit `/etc/pve-b2-age-backup/config.env` and ensure proper logging is set (defaults are usually sufficient). Check logs directly:
```bash
tail -f /var/log/pve-b2-age.log
```

### 2. Manual Hook Test
Simulate a backup finish event (careful not to delete real data):
```bash
# Create dummy file
touch /tmp/test-backup.tar.zst

# Run hook manually
sudo TARGET=/tmp/test-backup.tar.zst \
     STOREID=local \
     /usr/local/sbin/pve-b2-age-hook.sh backup-end snapshot 999
```
If upload and manifest succeed, the script deletes `/tmp/test-backup.tar.zst` after processing.

### 3. Generate Debug Report
Run this command to dump relevant system state to a file for sharing (scrub secrets!):
```bash
{
  echo "=== VERSIONS ==="
  rclone --version
  age --version
  pveversion
  echo -e "\n=== CONFIG (Scrubbed) ==="
  grep -vE "KEY|SECRET|PASS" /etc/pve-b2-age-backup/config.env
  echo -e "\n=== TIMERS ==="
  systemctl list-timers pve-b2-age*
  echo -e "\n=== LOG TAIL ==="
  tail -n 20 /var/log/pve-b2-age.log
} > /tmp/pve-b2-debug.txt
```

### Support Channels
- **GitHub Issues**: [LukasStrickler/proxmox-b2-offsite-backup/issues](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/issues)
- **Proxmox Forum**: [forum.proxmox.com](https://forum.proxmox.com)
