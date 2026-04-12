#!/usr/bin/env bash
set -euo pipefail

# export_copilot_pack.sh
# Creates a single ZIP package for Copilot review.
# Output: /opt/Documentation/exports/<repo>_copilot_pack_<timestamp>.zip

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

REPO_NAME="$(basename "$ROOT")"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$ROOT/exports"
OUT_ZIP="$OUT_DIR/${REPO_NAME}_copilot_pack_${TS}.zip"
MANIFEST="$OUT_DIR/${REPO_NAME}_copilot_pack_${TS}_MANIFEST.md"

mkdir -p "$OUT_DIR"

# Record metadata (helps Copilot stay up to date)
GIT_HEAD=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_HEAD="$(git rev-parse HEAD)"
fi

cat > "$MANIFEST" <<EOF
<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# Copilot Review Package Manifest

Generated: $(date)
Repo: $REPO_NAME
Git HEAD: ${GIT_HEAD:-N/A}

Included:
- README.md
- INDEX.md (if present)
- runbooks/**
- templates/**
- scripts/**
- .github/workflows/**

Excluded:
- .git/**
- exports/**
EOF

# Build zip
# Only include the canonical documentation surfaces.
FILES=()
[[ -f README.md ]] && FILES+=(README.md)
[[ -f INDEX.md ]] && FILES+=(INDEX.md)
[[ -d runbooks ]] && FILES+=(runbooks)
[[ -d templates ]] && FILES+=(templates)
[[ -d scripts ]] && FILES+=(scripts)
[[ -d .github/workflows ]] && FILES+=(.github)
FILES+=("$MANIFEST")

# Use python if available to avoid zip warnings, else fallback to zip.
if command -v python3 >/dev/null 2>&1; then
python3 - <<PY
import os, zipfile
from pathlib import Path
out_zip = Path("$OUT_ZIP")
root = Path("$ROOT")
items = [Path(p) for p in ${FILES!r}]

with zipfile.ZipFile(out_zip, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for p in items:
        p = Path(p)
        if not p.is_absolute():
            p = root / p
        if not p.exists():
            continue
        if p.is_dir():
            for f in p.rglob('*'):
                if f.is_dir():
                    continue
                # Exclude .git and exports
                parts = f.relative_to(root).parts
                if parts and parts[0] in ('.git','exports'):
                    continue
                z.write(f, f.relative_to(root).as_posix())
        else:
            rel = p.relative_to(root).as_posix() if p.is_absolute() else p.as_posix()
            z.write(p, rel)
print(out_zip)
PY
else
  command -v zip >/dev/null 2>&1 || { echo "zip not installed"; exit 2; }
  (cd "$ROOT" && zip -r "$OUT_ZIP" "${FILES[@]}" -x '.git/*' -x 'exports/*')
fi

echo "[OK] Created: $OUT_ZIP"
echo "[OK] Manifest: $MANIFEST"
echo "Upload the ZIP to Copilot for review."
