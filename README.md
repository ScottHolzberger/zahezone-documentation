<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# ZaheZone Documentation (Authoring Repository)

This repo is the **VS Code authoring workspace** for runbooks.

## Quick start

### Install shared pre-commit hook

```bash
./scripts/install_hooks.sh
```

### Generate/refresh Index

```bash
python3 scripts/generate_toc.py --docs-root . --out INDEX.md
```

### Run compliance locally

```bash
python3 scripts/check_runbooks.py --root . --mode all
```

## Policies

- Runbooks must live under `runbooks/<component>/`.
- Runbooks must include the authoritative header.
- Required headings are enforced by pre-commit and CI.
