# Initial Setup Workflow

> **Quick Setup**: Follow the [Quick Start Guide](../guides/quickstart.md) for streamlined installation in 10 minutes.

This document provides detailed planning guidance for initial deployment.

## Pre-Installation Planning

### Assess Your Environment

```bash
# List all VMs and their sizes
sudo qm list
sudo pct list

# Check VM disk usage
for vmid in $(sudo qm list | awk 'NR>1 {print $1}'); do
    echo "VM $vmid:"
    sudo qm config $vmid | grep -E '(scsi|sata|virtio|ide)'
done
```

### Calculate Storage Requirements

```
Largest VM size: 80 GB
Add 10% buffer: 8 GB
Staging quota: 88 GB → Round up to 100-120 GB
```

### Plan Backup Schedule

**Example schedule for 3 VMs**:
```
VM 101 (80GB): 02:00 - 04:00 (estimated 2 hours)
Buffer:        04:00 - 04:30 (30 minutes)
VM 102 (40GB): 04:30 - 05:30 (estimated 1 hour)
Buffer:        05:30 - 06:00 (30 minutes)
VM 103 (10GB): 06:00 - 06:30 (estimated 30 minutes)
Prune:         06:30 - 07:00
Host config:   07:00 Sunday
```

### Network Bandwidth Assessment

```bash
# Test actual bandwidth
speedtest-cli --no-download

# Calculate upload time:
# 80 GB × 8 = 640 Gb
# 640 Gb ÷ 100 Mbps = 6400 seconds ≈ 1.8 hours
```

## Setup Steps

Follow the [Quick Start Guide](../guides/quickstart.md) for:
1. Installing dependencies
2. Running the installer
3. **Downloading and securely storing** your encryption keys (`age.key`, `recipients.txt`) — required to restore backups later
4. Configuring B2
5. Setting up backup jobs
6. Testing your setup

## Next Steps

- [End-to-End Flow](end-to-end-flow.md) - Full path from install to recovery (scripted vs manual)
- [Scheduled Backups](scheduled-backups.md) - Detailed scheduling strategies
- [Disaster Recovery](disaster-recovery.md) - Recovery procedures
- [Troubleshooting](../troubleshooting/common-issues.md) - Common issues
