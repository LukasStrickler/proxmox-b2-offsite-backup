# End-to-End Flow: Install → Backup → Recovery

This document walks the full path from first install to recovery. **Scripts** are in bold; the table shows what is automated (scripts/timers) vs what you do yourself (manual). New to the project? Start with the [Quick Start Guide](../guides/quickstart.md), then use this page as a map.

---

## 1. Initial Setup (one-time)

| Step | What happens | Script vs manual |
|------|----------------|------------------|
| **Install** | Run installer: dependencies, scripts, systemd units, config template, optional age key generation | **`curl \| sudo bash`** (install.sh) |
| **Configure B2** | Create bucket and app key in Backblaze; configure rclone | Manual: Backblaze UI + **`rclone config`** |
| **Configure backup** | Set RCLONE_REMOTE, DUMPDIR, paths in config.env | Manual: edit `/etc/pve-b2-age-backup/config.env` |
| **Store keys** | Copy age.key and recipients.txt to offline storage | Manual (critical: without private key, no restore) |
| **Proxmox storage** | Add Directory storage for DUMPDIR | Manual: Proxmox UI |
| **Backup jobs** | One job per VM/CT, hook script set | Manual: Proxmox UI (Datacenter → Backup) |
| **Enable timers** | Prune (daily), hostconfig (weekly) | **`systemctl enable --now pve-b2-age-prune.timer pve-b2-age-hostconfig.timer`** |
| **Validate** | Pre-flight check | **`pve-b2-age-check.sh`** |

**Docs:** [Quick Start](../guides/quickstart.md), [Configuration](../guides/configuration.md)

---

## 2. Ongoing Backups (automated)

| What | Who runs it | Script |
|------|-------------|--------|
| VM/CT backup | Proxmox backup job | Proxmox calls **`pve-b2-age-hook.sh`** (encrypt → upload → manifest → delete local) |
| Monthly copy | Hook on 1st of month | Same hook copies daily → monthly |
| Prune old backups | systemd timer (e.g. 06:30 daily) | **`pve-b2-age-prune.sh`** |
| Host config backup | systemd timer (e.g. Sunday 07:00) | **`pve-b2-age-hostconfig.sh`** |

No manual steps once jobs and timers are enabled.

**Docs:** [Backup Operations](../guides/backup-operations.md), [Scheduled Backups](scheduled-backups.md)

---

## 3. Listing and Verification (optional, on demand)

| Task | Command |
|------|---------|
| List daily/monthly/logs/manifest/hostconfig | **`pve-b2-age-list.sh [tier]`** (e.g. `daily`, `all`, `hostconfig`) |
| List with download commands | **`pve-b2-age-list.sh -d daily`** |
| Verify a backup (download, decrypt, check hash) | **`pve-b2-age-verify.sh daily FILE.age`** |

---

## 4. Restore a Single VM or Container

| Step | What | Script |
|------|------|--------|
| List backups | See available files | **`pve-b2-age-list.sh daily`** (or `monthly`) |
| Restore | Download, decrypt, verify, run qmrestore/pct | **`pve-b2-age-restore.sh daily FILE.age NEW_VMID [storage]`** |
| Post-restore | Start VM/CT, remove decrypted file when done | Manual |

**Docs:** [Restore Operations](../guides/restore-operations.md)

---

## 5. Restore Host Configuration (e.g. after rebuild)

| Step | What | Script |
|------|------|--------|
| List hostconfig backups | See available host config archives | **`pve-b2-age-list.sh hostconfig`** |
| Restore latest or chosen file | Download, decrypt, optionally extract | **`pve-b2-age-restore-hostconfig.sh [--host HOST] [--extract-to DIR] [file.age]`** |
| Copy needed files into / | e.g. etc/network/interfaces | Manual |

**Docs:** [Restore Operations](../guides/restore-operations.md#restoring-host-configuration), [Disaster Recovery](disaster-recovery.md)

---

## 6. Full Disaster Recovery (new host or total loss)

High-level sequence; details in [Disaster Recovery](disaster-recovery.md).

1. **Rebuild** — Install Proxmox, storage, network (manual).
2. **Reinstall backup tooling** — Same one-line install or clone + **`./install.sh`** (script downloads from GitHub).
3. **Restore access** — rclone config, **restore age.key** to `/etc/pve-b2-age-backup/`, edit config.env (manual).
4. **Optional: host config** — **`pve-b2-age-restore-hostconfig.sh --host OLD_HOSTNAME --extract-to /tmp/restore`**, then copy files (script + manual).
5. **Restore VMs/CTs** — **`pve-b2-age-list.sh all`**, then **`pve-b2-age-restore.sh`** per VM/CT (scripted); re-create backup jobs and enable timers (manual).

**Doc:** [Disaster Recovery](disaster-recovery.md)

---

## Summary: What the scripts do

| Script | Purpose |
|--------|---------|
| **install.sh** | Install deps, scripts, systemd, config template, optional age keys |
| **pve-b2-age-hook.sh** | Encrypt and upload backup + manifest; delete local; monthly copy on 1st |
| **pve-b2-age-prune.sh** | Delete excess daily/monthly/logs on B2; rclone cleanup |
| **pve-b2-age-hostconfig.sh** | Tar /etc, pve-cluster, /root; encrypt and upload to B2 |
| **pve-b2-age-list.sh** | List backups (daily, monthly, logs, manifest, hostconfig, or all) |
| **pve-b2-age-verify.sh** | Download, decrypt, and verify SHA256 of a backup |
| **pve-b2-age-restore.sh** | Download, decrypt, verify, and run qmrestore/pct for one VM/CT |
| **pve-b2-age-restore-hostconfig.sh** | Download and decrypt host config backup; optional extract |
| **pve-b2-age-check.sh** | Pre-flight: deps, config, rclone, keys, storage, hook, timers |

Everything from “backup run” through “prune” and “hostconfig” is automated by scripts and systemd. Restore of a single VM/CT or host config is one or two script calls; full disaster recovery is scripted restore steps plus manual rebuild and re-configuration.
