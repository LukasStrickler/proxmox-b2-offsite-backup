# Contributing to PVE B2 Age Backup

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Code of Conduct

This project follows standard open source etiquette:
- Be respectful and constructive
- Focus on what's best for the community
- Welcome newcomers and help them learn

## How to Contribute

### Reporting Bugs & Enhancements

1. **Check Existing Issues**: Verify if the issue is already reported.
2. **Update**: Ensure you are running the latest version.
3. **Collect Details**:
   - Proxmox VE version and Script version/commit.
   - Debug logs (sanitized).
   - Configuration (secrets redacted).
   - Reproduction steps.

### Pull Requests

1. **Fork & Branch**: Create a feature branch (`git checkout -b feature/my-feature`).
2. **Implement**: Make focused, minimal changes.
3. **Test**: Verify on a Proxmox VE test environment.
4. **Lint**: Run `shellcheck` on modified scripts.
5. **Commit**: Use clear, descriptive messages with conventional format:
   ```
   type(scope): description
   
   Types: feat, fix, docs, refactor, test, chore
   Examples:
   - feat(hook): add zstd compression support
   - fix(prune): correct date calculation for monthly retention
   - docs: update configuration guide with new options
   ```
6. **Push & PR**: Submit your pull request with a summary of changes.

#### PR Guidelines
- One logical change per PR.
- Update documentation if behavior changes.
- Add comments for complex logic.

## Development Setup

### Prerequisites
- Proxmox VE test environment (VM recommended).
- Git and basic Bash scripting knowledge.
- Understanding of [Proxmox vzdump hooks](https://github.com/proxmox/pve-manager/blob/master/vzdump-hook-script.pl).

### Environment Setup

```bash
# Clone repository
git clone https://github.com/YOUR_USERNAME/proxmox-b2-offsite-backup.git
cd proxmox-b2-offsite-backup

# Install in development mode (symlink)
sudo ln -sf "$(pwd)/scripts/pve-b2-age-hook.sh" /usr/local/sbin/pve-b2-age-hook.sh.dev
```

### Testing Protocol

**Before submitting a PR, verify:**
1. **Syntax**: `bash -n scripts/*.sh` and `shellcheck scripts/*.sh`.
2. **Hook Phases**: Simulate backup phases manually.
   ```bash
   sudo /usr/local/sbin/pve-b2-age-hook.sh.dev backup-end snapshot 101
   ```
3. **Encryption**: Verify `age` encryption/decryption roundtrip.
4. **Transport**: Confirm `rclone` uploads to B2.
5. **Recovery**: Run a test restore operation.

## Coding Standards

### Bash Guidelines

All scripts must adhere to the patterns defined in `lib/common.sh`.

**Header & Boilerplate**:
```bash
#!/usr/bin/env bash
set -euo pipefail
# Source shared library (adjust path as needed)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
```

**Core Functions (`lib/common.sh`)**:
- **Logging**: Use `log "message"` (handles timestamps and file output).
- **Dependencies**: Use `need "cmd"` to verify binary existence.
- **Reliability**: Use `retry_with_backoff "cmd" [attempts] [delay]` for network calls.
- **Config**: Use `load_config` and `validate_config "VAR1" "VAR2"`.

**Style Rules**:
- **Quoting**: Quote ALL variables: `"$VAR"`.
- **Naming**: 
  - Environment/Config: `UPPER_CASE`
  - Local variables: `lower_case`
  - Functions: `snake_case` (`my_function`)
- **Error Handling**: Fail fast.
  ```bash
  # Good
  command || { log "ERROR: Failed"; exit 1; }
  ```

### Configuration & Docs

- **Config**: Use `.env` format. Document new variables in `.env.example` (repository root).
- **Docs**: Update `README.md` or `docs/` if parameters change. Keep language clear and concise.

## Project Structure

```
proxmox-b2-offsite-backup/
├── lib/               # Shared functions (common.sh)
├── scripts/           # Main executable scripts
├── systemd/           # Systemd unit files
├── docs/              # Guides and workflows
├── .env.example       # Configuration template
├── install.sh         # One-line installer
└── ...
```

## Security

Report security issues via [GitHub Issues](https://github.com/LukasStrickler/proxmox-b2-offsite-backup/issues).

### Contributor Security Checklist
- [ ] No secrets committed (API keys, private keys).
- [ ] Inputs validated and paths sanitized.
- [ ] Least privilege principles applied.

## Community

- **Issues**: Bug reports and feature requests.
- **Discussions**: General questions and ideas.

Contributors are recognized in commit history and release notes.

Thank you for improving PVE B2 Age Backup!
