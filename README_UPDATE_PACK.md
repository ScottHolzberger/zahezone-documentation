# Update Pack: make copilot-export + export pruning + manifest metadata

## What this adds

- `Makefile` target: `make copilot-export`
- `scripts/export_copilot_pack.sh` enhancements:
  - auto-regenerates `INDEX.md` (best effort)
  - embeds repo URL + branch + git HEAD into the manifest
  - auto-prunes old exports by age and by count

## Install

1. Unzip this pack into `/opt/Documentation`.
2. Ensure executable bit:
   ```bash
   chmod +x scripts/export_copilot_pack.sh
   ```
3. Commit and push.

## Usage

```bash
make copilot-export
```

## Prune tuning

Set env vars before running:

- `PRUNE_DAYS` (default 14)
- `PRUNE_KEEP` (default 30)

Example:

```bash
PRUNE_DAYS=7 PRUNE_KEEP=10 make copilot-export
```
