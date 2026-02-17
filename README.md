# [proxmox-b2-offsite-backup](https://github.com/LukasStrickler/proxmox-b2-offsite-backup)

<p align="center">
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="https://www.proxmox.com/"><img src="https://img.shields.io/badge/Proxmox-VE-blue" alt="Proxmox VE"></a>
  <a href="https://www.backblaze.com/cloud-storage"><img src="https://img.shields.io/badge/Backblaze-B2-red" alt="Backblaze B2"></a>
</p>

<p align="center">
  <strong>Secure, automated off-site backups for Proxmox VE</strong><br>
  Backblaze B2 · age encryption · rclone
</p>

---

## Overview

A **backup hook** for Proxmox VE: when a backup finishes, Proxmox runs our script so the backup file is encrypted and uploaded to Backblaze B2. Uses **age** for encryption and **rclone** for upload—minimal local disk (the file is removed after a successful upload).

| | |
|:---|:---|
| **Streaming encryption** | No plaintext left on disk |
| **SHA256 verification** | Manifest-based integrity checks |
| **Flexible retention** | N daily + monthly copies |
| **Systemd integration** | Prune and hostconfig timers |

## Quick Start

```bash
# 1. Install (inspect script first)
curl -fsSL https://raw.githubusercontent.com/LukasStrickler/proxmox-b2-offsite-backup/main/install.sh | sudo bash

# 2. Configure
sudo nano /etc/pve-b2-age-backup/config.env
sudo rclone config   # Add 'b2' remote

# 3. Enable timers
sudo systemctl enable --now pve-b2-age-prune.timer
sudo systemctl enable --now pve-b2-age-hostconfig.timer

# 4. Verify
sudo pve-b2-age-check.sh

# 5. In Proxmox UI: Datacenter → Backup → create a job → set Hook script to: /usr/local/sbin/pve-b2-age-hook.sh
```

**Important:** After install, download and securely store your encryption keys (`age.key` and `recipients.txt`) to an offline, safe location. Without the private key you cannot restore backups.

→ [Quick Start Guide](docs/guides/quickstart.md)

## Requirements

| Requirement | Details |
|:---|:---|
| Proxmox VE | 7.x or 8.x (restore uses `qmrestore`, `pct`) |
| Local storage | Largest VM + ~10% for staging |
| Backblaze B2 | Bucket + Application Key |
| **Runtime dependencies** | **rclone**, **age**, **jq**, **zstd** — installed by install script if missing. **flock**, **sha256sum**, **tar** — from util-linux/coreutils (standard on Debian/Proxmox). **curl** — install-only. |

## Documentation

| Guide | Description |
|:---|:---|
| [Quick Start](docs/guides/quickstart.md) | Install and first backup |
| [End-to-End Flow](docs/workflows/end-to-end-flow.md) | Install → backup → recovery (what is scripted vs manual) |
| [Configuration](docs/guides/configuration.md) | Options and tuning |
| [Backup Operations](docs/guides/backup-operations.md) | Manual runs, monitoring |
| [Restore Operations](docs/guides/restore-operations.md) | Recovery steps |
| [Scheduled Backups](docs/workflows/scheduled-backups.md) | Timers and schedules |
| [Disaster Recovery](docs/workflows/disaster-recovery.md) | Full restore workflow |
| [Troubleshooting](docs/troubleshooting/common-issues.md) | Debugging |

## Security

- **Age encryption** — Public keys for backup; private key only for restore. [age](https://github.com/FiloSottile/age)
- **Least privilege** — Backup host cannot decrypt; restore on a separate machine if needed.
- **Multiple recipients** — Redundancy and key rotation supported.
- **Reporting** — Issues? [GitHub Issues](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/issues)

## Contributing & Support

| | |
|:---|:---|
| **Contribute** | [CONTRIBUTING.md](CONTRIBUTING.md) |
| **License** | [MIT](LICENSE) |
| **Issues** | [Report a bug](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/issues) |
| **Discussions** | [Q&A & ideas](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/discussions) |

## Acknowledgments

**Built on** — [age](https://github.com/FiloSottile/age), [rclone](https://rclone.org/) (dependencies we use).

**Inspired by** — [padelt/vzdump-plugin-b2](https://github.com/padelt/vzdump-plugin-b2), [proxmox-vzbackup-rclone](https://github.com/TheRealAlexV/proxmox-vzbackup-rclone), [PERB](https://github.com/flip-flop-foundry/Proxmox-Encrypted-Remote-Backup) (related Proxmox backup projects).

---

<p align="center"><em>Encrypted off-site backups for Proxmox. MIT <a href="LICENSE">LICENSE</a>.</em></p>
