---
name: Bug Report
about: Report a bug to help us improve
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description

A clear and concise description of what the bug is.

## Environment

**Proxmox VE:**
- Version: [e.g., 8.1.3]

**PVE B2 Age Backup:**
- Version/Commit: [e.g., v0.1.0 or commit hash]

**Dependencies:**
- rclone version: [run `rclone --version`]
- age version: [run `age --version`]
- jq version: [run `jq --version`]

## Steps to Reproduce

1. Go to '...'
2. Click on '....'
3. Run command '....'
4. See error

## Expected Behavior

A clear and concise description of what you expected to happen.

## Actual Behavior

A clear and concise description of what actually happened.

## Logs

```
Paste relevant log output here
Run: sudo tail -n 100 /var/log/pve-b2-age.log
```

**Remember to sanitize logs** - remove:
- B2 bucket names
- Age public keys
- IP addresses
- VM names (if sensitive)

## Configuration

**Sanitized config.env** (remove secrets):
```bash
RCLONE_REMOTE="b2:***"
DUMPDIR="/backup/vzdump"
AGE_RECIPIENTS="/etc/pve-b2-age-backup/recipients.txt"
# ... other settings
```

## Checklist

- [ ] I have searched [existing issues](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/issues)
- [ ] I have checked the [Troubleshooting Guide](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/blob/main/docs/troubleshooting/common-issues.md)
- [ ] I am using the latest version
- [ ] I have sanitized sensitive information from logs and config

## Additional Context

Add any other context about the problem here.

**Screenshots** (if applicable):
If applicable, add screenshots to help explain your problem.

## Debug Information

<details>
<summary>Click to expand debug output</summary>

```bash
# Run this and paste output
echo "=== System Info ==="
pveversion -v
echo ""
echo "=== Package Versions ==="
rclone --version | head -1
age --version 2>&1 || echo "age not found"
jq --version
echo ""
echo "=== Disk Usage ==="
df -h
echo ""
echo "=== Backup Jobs ==="
cat /etc/pve/jobs.cfg 2>/dev/null || echo "No jobs configured"
```

</details>

---

**Resources:**
- [Troubleshooting Guide](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/blob/main/docs/troubleshooting/common-issues.md)
- [Configuration Guide](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/blob/main/docs/guides/configuration.md)
- [GitHub Discussions](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/discussions)
