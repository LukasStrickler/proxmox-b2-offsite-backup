# Pull Request

## Description

<!-- Provide a clear and concise description of your changes -->

Fixes # (issue)

## Type of Change

<!-- Mark the relevant option with an 'x' -->

- [ ] 🐛 Bug fix (non-breaking change which fixes an issue)
- [ ] ✨ New feature (non-breaking change which adds functionality)
- [ ] 💥 Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] 📚 Documentation update
- [ ] 🔧 Configuration change
- [ ] 🧹 Code cleanup/refactoring
- [ ] ⚡ Performance improvement

## Checklist

<!-- Mark completed items with an 'x' -->

### Code Quality

- [ ] My code follows the style guidelines of this project
- [ ] I have performed a self-review of my own code
- [ ] I have commented my code, particularly in hard-to-understand areas
- [ ] I have made corresponding changes to the documentation

### Testing

- [ ] I have tested my changes on Proxmox VE
- [ ] My changes generate no new warnings
- [ ] I have tested the backup hook with a real backup job
- [ ] I have tested restore operations (if applicable)
- [ ] I have tested prune operations (if applicable)

### Documentation

- [ ] I have updated the README.md (if needed)
- [ ] I have updated relevant guides in docs/
- [ ] I have updated .env.example (if adding new configuration options)
- [ ] I have updated AGENTS.md (if architectural changes were made)

### Security

- [ ] My changes do not introduce security vulnerabilities
- [ ] File permissions are correct (0600/0700 for sensitive files)
- [ ] No secrets or credentials are committed
- [ ] Error handling is secure (no sensitive data in error messages)

## Testing

### Test Environment

- **Proxmox VE Version**:
- **Test VM/CT IDs used**:
- **Storage type** (ZFS/LVM/Directory):

### Test Cases

<!-- Describe the tests you ran to verify your changes -->

1. **Test 1**: Description
   - Command: ``
   - Expected:
   - Actual:

2. **Test 2**: Description
   - Command: ``
   - Expected:
   - Actual:

### Test Results

```
Paste relevant test output here
```

## Changes Made

### Files Changed

<!-- List all files modified -->

- `scripts/pve-b2-age-hook.sh` - Description of changes
- `.env.example` - New configuration options

### Configuration Changes

<!-- If new configuration options were added -->

```bash
# New configuration options
NEW_OPTION="default_value"  # Description of what this does
```

## Breaking Changes

<!-- If this PR introduces breaking changes, describe them here -->

**Breaking Change Description:**

**Migration Guide:**

```bash
# Steps to migrate from previous version
```

## Additional Context

<!-- Add any other context about the PR here -->

## Screenshots (if applicable)

<!-- Add screenshots to help explain your changes -->

## Related Issues/PRs

- Related to #
- Depends on #
- Supersedes #

---

## For Maintainers

<!-- Leave this section for maintainers -->

- [ ] Code review completed
- [ ] Documentation review completed
- [ ] Tested on Proxmox VE
- [ ] Version bump needed

---

**Resources:**
- [Contributing Guide](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/blob/main/CONTRIBUTING.md)
- [Code Style Guidelines](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/blob/main/AGENTS.md#code-style-guidelines)
