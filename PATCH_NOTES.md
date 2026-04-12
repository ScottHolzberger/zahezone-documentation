# Patch Notes — Documentation Automation

## What this adds

1) Pre-commit hook now:
- Enforces runbook compliance on staged runbooks
- Regenerates INDEX.md and stages it automatically

2) Export script:
- Creates a single ZIP package (runbooks/templates/scripts/workflows + manifest)
- Designed to be uploaded into Copilot for full review

## Install

```bash
chmod +x .githooks/pre-commit scripts/export_copilot_pack.sh
./scripts/install_hooks.sh
```

## Export for Copilot review

```bash
./scripts/export_copilot_pack.sh
```

The ZIP will be created under `exports/`.
