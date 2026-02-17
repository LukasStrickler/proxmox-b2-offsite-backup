# Scheduled Backups Workflow

Best practices for scheduling and managing automated backups.

## Backup Lifecycle

The automated backup process consists of three distinct phases that must be scheduled carefully to avoid conflicts.

```mermaid
timeline
    02:00 : VM Backup Start : vzdump creates local file
          : Hook Execution : Encrypts & streams to B2
    06:30 : Prune Timer : Removes old B2 files
    07:00 : Host Config : Archives /etc & /root (Weekly)
```

## Staging: One Backup at a Time

Staging (`DUMPDIR`) holds the plaintext backup **only until the hook has uploaded it to B2**. The hook deletes the local file only after a successful upload. So:

- **At most one backup file** should be in staging at once if space is limited (e.g. 100GB for 8×80GB VMs).
- The hook **enforces** this by default: at **backup-start** it checks for any existing backup file in `DUMPDIR`. If one is present (another job in progress or a leftover), it **exits with an error** so the new backup does not start and fill the disk.
- **You must schedule jobs** so the next backup starts only after the previous one has **finished** (vzdump done + upload done + file deleted). The lock ensures only one upload runs at a time; the staging check ensures the next job does not start while a file is still on disk.

**Example (100GB staging, 8×80GB VMs):**  
Schedule each VM in a separate window, e.g. 2h apart (1h dump + 1h upload): 02:00, 04:00, 06:00, … so only one backup file exists at a time. If a job fails with “Staging busy”, either another backup is still uploading or a leftover file remains — wait or remove it and retry.

To allow multiple backup files in staging (e.g. very large DUMPDIR), set `ALLOW_CONCURRENT_STAGING=true` in `config.env`. See [Configuration](../guides/configuration.md).

## Scheduling Strategy

### Core Principles

1.  **Stagger Jobs**: Never run multiple backup jobs simultaneously (with default staging enforcement, the hook will fail the second job if staging is still busy).
2.  **Buffer Time**: Add enough time between jobs for dump + upload to finish (e.g. 2h per 80GB VM at 100 Mbps).
3.  **Traffic Management**: Schedule largest VMs during lowest network activity.
4.  **Sequence**: Run backups first, then prune, then host config.

### Estimating Durations

Calculate window size based on VM size and upload speed:

> **Formula**: `(VM Size × 8) ÷ Upload Speed + 30m Overhead`

| VM Size | Upload Speed | Est. Window |
| :--- | :--- | :--- |
| 50 GB | 100 Mbps | ~1.5 hours |
| 100 GB | 100 Mbps | ~2.5 hours |
| 500 GB | 100 Mbps | ~12 hours |

*Monitor `/var/log/pve-b2-age.log` for actual durations to refine schedules.*

## Recommended Schedules

### Small Environment (<100GB total)
*Single nightly window.*

```cron
# VM 101 (50GB)
0 2 * * *
# VM 102 (30GB) - starts 2h later
0 4 * * *
# Prune (Daily)
0 7 * * *
# Host Config (Sundays)
30 7 * * 0
```

### Medium Environment (100-500GB)
*Extended nightly window.*

```cron
# VM 101 (100GB)
0 0 * * *
# VM 102 (80GB)
30 3 * * *
# VM 103 (60GB)
30 6 * * *
# Prune (Daily)
0 15 * * *
```

### Large Environment (>500GB)
*Split across days to avoid 24h saturation.*

```yaml
Monday:   VM 101 (200GB) at 00:00
Tuesday:  VM 104-106 at 00:00
Wednesday: VM 107-110 at 00:00
...
Daily:    Prune at 20:00
Sunday:   Host Config at 22:00
```

## Creating Backup Jobs

### Via Proxmox Web UI

1.  Go to **Datacenter → Backup → Add**.
2.  **Schedule**: Set based on your plan (e.g., `0 2 * * *`).
3.  **Selection**: Select **ONE** specific VM per job.
    *   *Why?* Ensures granular control and easier retries.
4.  **Mode**: `Snapshot`.
5.  **Compression**: `ZSTD` (fast & efficient).
6.  **Hook Script**: `/usr/local/sbin/pve-b2-age-hook.sh`.

### Via Command Line

```bash
# Create job for VM 101 at 2 AM
pvesh create /cluster/backup \
    --storage backup-vzdump \
    --schedule '0 2 * * *' \
    --vmid 101 \
    --mode snapshot \
    --compress zstd \
    --script /usr/local/sbin/pve-b2-age-hook.sh
```

## Maintenance Timers

Two systemd timers handle maintenance tasks independent of VM backups.

### Prune Timer (`pve-b2-age-prune.timer`)
Runs daily to enforce retention policies defined in `config.env`.

```bash
# Check status and next run time
systemctl list-timers pve-b2-age-prune.timer

# Edit schedule (default: 06:30)
sudo systemctl edit pve-b2-age-prune.timer --full
```

### Host Config Timer (`pve-b2-age-hostconfig.timer`)
Runs weekly (Sunday) to backup PVE configuration files.

```bash
# Trigger manually for testing
sudo systemctl start pve-b2-age-hostconfig.service
```

## Retention Policy

Retention is configured in `/etc/pve-b2-age-backup/config.env`. The prune script uses these settings to delete old backups from B2.

| Setting | Description | Recommended |
| :--- | :--- | :--- |
| `KEEP_DAILY` | Recent backups | `7-14` |
| `KEEP_MONTHLY` | Long-term archiving | `1-3` |
| `KEEP_LOGS` | Log retention (days) | `30` |

*See [Configuration Guide](../guides/configuration.md) for full details.*

## Operational Monitoring

### Daily Checks
1.  **Verify Logs**: Check `/var/log/pve-b2-age.log` for `ERROR` or `WARN`.
2.  **Check Staging**: Ensure `/backup/vzdump` is empty (no stuck files).
3.  **Verify Count**: Run `pve-b2-age-list.sh` to confirm new backups exist.

### Automated Health Check
Create a simple cron script to alert on failures:

```bash
#!/bin/bash
# Check for errors in the last 24h
if grep -q "ERROR" /var/log/pve-b2-age.log; then
    echo "Backup errors detected" | mail -s "Backup Alert" YOUR_EMAIL
fi
```

### Handling Failures
*   **Job Fails**: Check `TARGET` variable in hook logs. If undefined, vzdump failed before the hook ran.
*   **Prune Fails**: Verify B2 credentials and network connectivity using `rclone lsf b2:BUCKET`.
*   **Stuck Locks**: If a job hangs, clear the lock file at `/run/lock/pve-b2-age-hook.lock`.

*For detailed troubleshooting, see [Common Issues](../troubleshooting/common-issues.md).*

## Seasonal Maintenance

### Adding New VMs
1.  **Size**: Estimate backup size and duration.
2.  **Schedule**: Find a gap in the existing timetable.
3.  **Test**: Run a manual backup with the hook script to verify B2 upload.

### Maintenance Windows
Disable timers to prevent conflicts during system work:

```bash
sudo systemctl stop pve-b2-age-prune.timer pve-b2-age-hostconfig.timer
# ... perform maintenance ...
sudo systemctl start pve-b2-age-prune.timer pve-b2-age-hostconfig.timer
```
