# Backup Operations Guide

Managing daily backup operations, schedules, and health checks for PVE B2 Age Backup.

## Job Management

### Staggered Scheduling (Recommended)

To prevent disk I/O contention and network saturation, avoid running all backups simultaneously.

**Recommended Schedule:**
```
VM 101 (80GB):   02:00
VM 102 (40GB):   04:00
VM 103 (10GB):   05:00
```
*Calculate gaps based on typical backup duration + 30 minute buffer.*

### Why Not Use "All"?
Proxmox runs "All" selection jobs in parallel. This often causes:
- **Staging Space Exhaustion**: Multiple VMs dumping to local disk at once.
- **I/O Choke**: High latency for running VMs.
- **Upload Conflicts**: Bandwidth saturation.

> **Tip**: Create individual backup jobs for each VM in `Datacenter > Backup`.
> See [Quick Start Guide](quickstart.md) for job creation steps.

## Monitoring & Daily Checks

### Check Status
```bash
# Check systemd timers
systemctl status pve-b2-age-prune.timer
systemctl status pve-b2-age-hostconfig.timer

# View execution history
systemctl list-timers pve-b2-age-*
```

### Log Monitoring
```bash
# Watch live logs
sudo tail -f /var/log/pve-b2-age.log

# Check recent errors
sudo grep "ERROR" /var/log/pve-b2-age.log | tail -20
```

### Proxmox UI
1. Go to **Datacenter → Cluster → Task History**.
2. Filter for `vzdump`.
3. Verify status is **OK**.

## Listing Backups

Use the `pve-b2-age-list.sh` tool to query remote backups.

| Action | Command |
|--------|---------|
| **List Daily** | `sudo pve-b2-age-list.sh daily` |
| **List Monthly** | `sudo pve-b2-age-list.sh monthly` |
| **List Specific VM** | `sudo pve-b2-age-list.sh --vmid 101 daily` |
| **Verbose Mode** | `sudo pve-b2-age-list.sh -v daily` |
| **Get Download Cmd** | `sudo pve-b2-age-list.sh -d daily` |
| **JSON Output** | `sudo pve-b2-age-list.sh -j daily` |

## Retention Management

Pruning is handled automatically by `pve-b2-age-prune.service` (default: 06:30 daily).

### Configuration
Edit `/etc/pve-b2-age-backup/config.env`:

```bash
# Strategy: Conservative (High Safety)
KEEP_DAILY=14       # 2 weeks
KEEP_MONTHLY=3      # 3 months
KEEP_LOGS=90

# Strategy: Aggressive (Cost Saving)
KEEP_DAILY=3
KEEP_MONTHLY=1
KEEP_LOGS=7
```

### Manual Pruning
```bash
# Dry run (safe test)
sudo pve-b2-age-prune.sh --dry-run

# Execute prune
sudo pve-b2-age-prune.sh
```

## Host Configuration Backup

Archives `/etc`, `/var/lib/pve-cluster`, `/root`, `/usr/local/sbin`, and `/usr/local/bin` to B2.
When `sqlite3` is available, it stores a consistent snapshot of `config.db`
inside the archive before upload.

### Schedule
Runs automatically via `pve-b2-age-hostconfig.timer` (Default: Sundays at 07:00).

### Manual Run
```bash
sudo pve-b2-age-hostconfig.sh
```

> **To Restore**: See [Restore Operations Guide](restore-operations.md#restoring-host-configuration).

## Manual Operations

### Trigger Backup via CLI
Useful for ad-hoc backups or testing.

```bash
# Backup VM 101
sudo vzdump 101 --storage backup-vzdump --mode snapshot

# With email notification
sudo vzdump 101 --storage backup-vzdump --mode snapshot --mailto YOUR_EMAIL
```

### Test Hook Script
Verify the hook logic without running a full backup.

```bash
# Validate hook syntax
sudo bash -n /usr/local/sbin/pve-b2-age-hook.sh
```
*For a runtime simulation, use the manual hook test in [Troubleshooting](../troubleshooting/common-issues.md#2-manual-hook-test).*

## Troubleshooting

### Quick Connectivity Check
```bash
# List remote bucket contents
sudo rclone lsf b2:YOUR_BUCKET_NAME

# Verify remote is reachable and bucket listing works
sudo rclone lsd b2:
```

### Common Error Patterns
- **"No space left on device"**: Staging partition full. Clean up `/backup/vzdump`.
- **"Upload failed"**: Check internet connection or B2 credentials.
- **"Age encryption failed"**: Verify `recipients.txt` permissions and content.
- **Recent backup not visible yet**: Wait briefly and list again; object listings can lag right after write/delete.

> **Full Guide**: See [Common Issues](../troubleshooting/common-issues.md) for detailed solutions.

## Automation Snippets

### Health Check Script
Run via cron to get email alerts on failure.

```bash
#!/bin/bash
# /usr/local/bin/check-backup-health.sh
LOG="/var/log/pve-b2-age.log"
EMAIL="YOUR_EMAIL"

# Count errors in last 24h (including today)
ERRORS=$(grep "ERROR" "$LOG" | grep -E "$(date -d '1 day ago' +%Y-%m-%d)|$(date +%Y-%m-%d)" | wc -l)

if [[ $ERRORS -gt 0 ]]; then
    echo "Backup errors: $ERRORS" | mail -s "Backup Alert: $(hostname)" "$EMAIL"
fi

# Check remote existence
COUNT=$(sudo pve-b2-age-list.sh -j daily | jq '.tiers.daily | length')
if [[ $COUNT -eq 0 ]]; then
    echo "No remote backups found!" | mail -s "CRITICAL: Zero Backups" "$EMAIL"
fi
```

### Metrics (Prometheus/Grafana)
Parse logs for dashboard data:
```bash
# Upload success count
grep -c "deleted local plaintext" /var/log/pve-b2-age.log

# Last upload duration
grep "uploading encrypted backup" /var/log/pve-b2-age.log | tail -1
```
