# AGENTS.md - AI Agent Instructions for PVE B2 Age Backup

## Project Overview

**Repository**: https://github.com/LukasStrickler/proxmox-b2-offsite-backup
**Purpose**: Encrypted off-site backup solution for Proxmox VE using age encryption and Backblaze B2
**Primary Technologies**: Bash, Proxmox VE, age encryption, rclone, Backblaze B2, systemd

---

## Quick Reference Links

### Primary Documentation
- **Main README**: `README.md`
- **Quick Start Guide**: `docs/guides/quickstart.md`
- **Configuration Guide**: `docs/guides/configuration.md`
- **Workflows**: `docs/workflows/`

### Official References
- **Proxmox vzdump hooks**: https://github.com/proxmox/pve-manager/blob/master/vzdump-hook-script.pl
- **age encryption**: https://github.com/FiloSottile/age
- **rclone B2 docs**: https://rclone.org/b2/
- **rclone rcat**: https://rclone.org/commands/rclone_rcat/
- **Backblaze B2 docs**: https://www.backblaze.com/docs/cloud-storage-about-backblaze-b2-cloud-storage
- **systemd timers**: https://man7.org/linux/man-pages/man5/systemd.timer.5.html

### Related Projects (Research Sources)
- **vzdump-plugin-b2 (padelt)**: https://github.com/padelt/vzdump-plugin-b2
- **proxmox-vzbackup-rclone**: https://github.com/TheRealAlexV/proxmox-vzbackup-rclone
- **PERB (flip-flop-foundry)**: https://github.com/flip-flop-foundry/Proxmox-Encrypted-Remote-Backup
- **proxmox-grapple**: https://github.com/lingfish/proxmox-grapple
- **borgmatic**: https://github.com/borgmatic-collective/borgmatic
- **rsnapshot**: https://github.com/rsnapshot/rsnapshot

---

## Architecture

### Hook Phase Model (Proxmox vzdump)
- `backup-start`: Called when VM/CT backup begins
- `backup-end`: Called when backup completes (TARGET env var available)
- `log-end`: Called when log finalizes (LOGFILE env var available)
- `backup-abort`: Called on backup failure

### Data Flow
1. Proxmox vzdump creates local backup file
2. Hook script encrypts with age (streaming)
3. Encrypted data uploaded to B2 via rclone rcat
4. Manifest uploaded for integrity verification
5. Local plaintext deleted on success
6. Retention policy enforced via separate prune script

### Directory Structure
```
/etc/pve-b2-age-backup/     # Configuration
/usr/local/sbin/            # Executable scripts
/etc/systemd/system/        # Timer/service units
/var/log/                   # Log files
```

### Remote Storage Layout (B2)
```
b2:BUCKET/proxmox/HOSTNAME/
├── daily/           # Daily backups
├── monthly/         # Monthly backups (copies)
├── logs/            # Vzdump logs
├── manifest/        # Integrity manifests (JSON)
└── hostconfig/      # Host configuration backups
```

---

## Critical Implementation Details

### Staging and Concurrency
- **One backup file at a time** by default: space in `DUMPDIR` is only freed after the hook uploads in `backup-end` and deletes the local file. With limited staging (e.g. 100GB for 8×80GB VMs), jobs must not overlap.
- **backup-start check**: The hook fails `backup-start` if any `vzdump-qemu-*` or `vzdump-lxc-*` file already exists in `DUMPDIR`, so a second job does not start and fill the disk. Set `ALLOW_CONCURRENT_STAGING=true` to disable (only if staging is large enough).
- **Lock**: `flock` on `backup-end` serializes uploads; it does not stop vzdump from starting, hence the staging check.

### Environment Variables (Proxmox vzdump)
- `TARGET` / `TARFILE`: Path to backup file (only in `backup-end` phase)
- `LOGFILE`: Path to log file (only in `log-end` phase)
- `VMID`: VM/CT identifier
- `MODE`: Backup mode (snapshot, suspend, stop)
- `HOSTNAME`: Target hostname
- `DUMPDIR`: Backup directory
- `STOREID`: Storage ID

### Age Encryption Patterns
- Use recipient file (`-R recipients.txt`) for encryption
- Identity file (`-i age.key`) only needed for restore/verify
- Stream encryption: `age -R recipients.txt < plaintext > encrypted`
- Stream decryption: `age -d -i age.key < encrypted > plaintext`

### Rclone B2 Patterns
- Use `--b2-hard-delete` for permanent deletion in prune operations
- Use `--fast-list` for efficient listing (reduces API calls)
- Use `--streaming-upload-cutoff` to control RAM usage
- Default retention: use B2 lifecycle rules + prune script

### Retry Logic
- Exponential backoff: `delay = BASE_BACKOFF * (2 ^ (attempt - 1))`
- Default: 6 attempts with 20s base backoff
- File lock prevents parallel hook execution

---

## Security Considerations

### File Permissions
- Configuration: `/etc/pve-b2-age-backup/` should be `0700`
- Age identity (private key): `0600`
- Age recipients (public keys): `0644` or `0640`
- Scripts: `0700` (executed as root)

### Key Management
- Backup host should ONLY have recipients.txt (public keys)
- Keep age.key (private key) offline or on separate restore host
- Never commit private keys to repository
- Consider post-quantum recipients: `age-keygen -pq`

### Network Security
- B2 credentials stored in rclone config (not in repo)
- Use application keys restricted to backup bucket
- Enable bucket lifecycle rules for version control

---

## Common Tasks for Agents

### Adding New Scripts
1. Place in `scripts/` with `.sh` extension
2. Add shebang `#!/usr/bin/env bash`
3. Use `set -euo pipefail`
4. Include config sourcing: `source /etc/pve-b2-age-backup/config.env`
5. Install to `/usr/local/sbin/` via install script

### Modifying Configuration
1. Update `.env.example`
2. Update `docs/guides/configuration.md`
3. Update relevant script to handle new option with default
4. Consider migration path for existing installs

### Adding Documentation
1. Follow Divio documentation system:
   - Tutorials: Learning-oriented
   - How-to guides: Goal-oriented
   - Reference: Information-oriented
   - Explanation: Understanding-oriented
2. Use `docs-write` skill for guidance
3. Include code examples and expected output
4. Cross-reference related docs

### Testing Changes
1. Test on Proxmox VE environment
2. Verify hook phases work correctly
3. Test encryption/decryption roundtrip
4. Verify B2 uploads and downloads
5. Check systemd timer activation

---

## Code Style Guidelines

### Bash Scripts
- Always use `set -euo pipefail`
- Quote all variables: `"$VAR"`
- Use lowercase for local variables
- Use UPPERCASE for environment variables
- Functions: lowercase with dashes
- Error handling: `|| { log "ERROR: ..."; exit 1; }`

### Configuration
- Use `.env` format (sourcable by bash)
- Include comments explaining each option
- Provide sensible defaults
- Mark required vs optional settings

### Documentation placeholders
- **Placeholder names**: Use ALL CAPS and underscores only. Capitalize existing placeholders; turn hyphens into underscores (e.g. `your-bucket` → `YOUR_BUCKET`, `your-bucket-name` → `YOUR_BUCKET_NAME`, `bucket` → `BUCKET`). Do not use lowercase or hyphens in docs or examples. Check README, guides, workflows, AGENTS.md, .env.example, and install.sh.

### Logging
- Use consistent format: `DATE [COMPONENT] MESSAGE`
- Log to `/var/log/pve-b2-age.log` by default
- Use syslog identifiers for systemd services

---

## External Dependencies

### Required Packages
```bash
apt install -y rclone age jq
```

### Rclone Configuration
```bash
rclone config
# Type: b2
# Account: B2 Key ID
# Key: B2 Application Key
```

### Backblaze B2 Setup
1. Create bucket at https://secure.backblaze.com/b2_buckets.htm
2. Create application key restricted to bucket
3. Configure lifecycle rules (optional but recommended)

---

## Troubleshooting References

### Common Log Locations
- Hook operations: `/var/log/pve-b2-age.log`
- Restore operations: `/var/log/pve-b2-age-restore.log`
- Systemd services: `journalctl -u pve-b2-age-*`

### Debug Commands
```bash
# Test rclone connectivity
rclone lsf b2:YOUR_BUCKET

# Test age encryption
echo "test" | age -r age1... > test.age
cat test.age | age -d -i age.key

# Check hook environment
/usr/local/sbin/pve-b2-age-hook.sh backup-end snapshot 101

# List backups (tiers: daily, monthly, logs, manifest, hostconfig, all)
pve-b2-age-list.sh -v daily
pve-b2-age-list.sh hostconfig

# Restore host config (latest or specific file)
pve-b2-age-restore-hostconfig.sh [--extract-to DIR] [filename.age]
```

---

## Project Philosophy

This is a focused, single-purpose backup utility. We intentionally avoid:
- **SECURITY.md** — Security issues can be reported via GitHub Issues
- **CHANGELOG.md** — Commit history and git tags serve this purpose for small projects
- **Formal release process** — This is a personal utility, not enterprise software

Keep documentation lean and actionable. If a document doesn't help users accomplish a task, remove it.

---

## Version History and Breaking Changes

### Versioning Strategy
- Use semantic versioning (MAJOR.MINOR.PATCH)
- Tag releases in git with version numbers
- Document breaking changes in commit messages

### Current Considerations
- This is initial setup (v0.1.0)
- Configuration format may evolve
- Script locations are fixed after install

---

## Agent Self-Check Before Modifications

Before modifying any code, verify:
- [ ] You understand the hook phase being modified
- [ ] File permissions will remain secure
- [ ] Error handling is preserved
- [ ] Configuration is backward compatible
- [ ] Documentation is updated to match
- [ ] Logging is consistent

---

## Contact and Support

- **Issues**: https://github.com/LukasStrickler/proxmox-b2-offsite-backup/issues
- **Discussions**: https://github.com/LukasStrickler/proxmox-b2-offsite-backup/discussions

---

*This file should be updated whenever architectural decisions change or new patterns are established.*
