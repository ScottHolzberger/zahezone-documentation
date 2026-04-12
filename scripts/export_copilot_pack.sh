#!/usr/bin/env bash
set -euo pipefail

# export_copilot_pack.sh
# Creates a single ZIP package for Copilot review.
# Output: exports/<repo>_copilot_pack_<timestamp>.zip
# Also prunes old exports.

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

REPO_NAME="$(basename "$ROOT")"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$ROOT/exports"
OUT_ZIP="$OUT_DIR/${REPO_NAME}_copilot_pack_${TS}.zip"
MANIFEST="$OUT_DIR/${REPO_NAME}_copilot_pack_${TS}_MANIFEST.md"

# Prune policy (override via env)
PRUNE_DAYS="${PRUNE_DAYS:-14}"
PRUNE_KEEP="${PRUNE_KEEP:-30}"

mkdir -p "$OUT_DIR"

# Ensure INDEX.md is current before export (best effort)
if [[ -f scripts/generate_toc.py ]]; then
  python3 scripts/generate_toc.py --docs-root "$ROOT" --out INDEX.md >/dev/null 2>&1 || true
fi

GIT_HEAD="N/A"
BRANCH="N/A"
REPO_URL="N/A"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_HEAD="$(git rev-parse HEAD)"
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  REPO_URL="$(git remote get-url origin 2>/dev/null || echo N/A)"
fi

cat > "$MANIFEST" <<EOF
<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# Copilot Review Package Manifest

Generated: $(date)
Repository: $REPO_NAME
Repository URL: $REPO_URL
Branch: $BRANCH
Git HEAD: $GIT_HEAD

Included:
- README.md (if present)
- INDEX.md (if present)
- runbooks/**
- templates/**
- scripts/**
- .github/workflows/**
- This manifest

Excluded:
- .git/**
- exports/** (previous exports)
EOF

python3 <<PY
from pathlib import Path
import zipfile

root = Path("$ROOT")
out_zip = Path("$OUT_ZIP")
manifest = Path("$MANIFEST")

include_dirs = [
    "runbooks",
    "templates",
    "scripts",
    ".github/workflows",
]

include_files = [
    "README.md",
    "INDEX.md",
]

with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in include_files:
        p = root / rel
        if p.exists():
            z.write(p, p.relative_to(root))

    for d in include_dirs:
        base = root / d
        if not base.exists():
            continue
        for f in base.rglob("*"):
            if f.is_dir():
                continue
            rel = f.relative_to(root)
            if rel.parts and rel.parts[0] in {".git", "exports"}:
                continue
            z.write(f, rel)

    if manifest.exists():
        z.write(manifest, manifest.relative_to(root))

print(f"[OK] Created: {out_zip}")
PY

# --- Prune old exports ---

# 1) time-based prune
find "$OUT_DIR" -maxdepth 1 -type f \( -name '*_copilot_pack_*.zip' -o -name '*_copilot_pack_*_MANIFEST.md' \) -mtime +"$PRUNE_DAYS" -print -delete 2>/dev/null || true

# 2) count-based prune (keep newest PRUNE_KEEP zips)
mapfile -t zips < <(ls -1t "$OUT_DIR"/*_copilot_pack_*.zip 2>/dev/null || true)
if [[ ${#zips[@]} -gt $PRUNE_KEEP ]]; then
  for ((i=PRUNE_KEEP; i<${#zips[@]}; i++)); do
    oldzip="${zips[$i]}"
    oldman="${oldzip%.zip}_MANIFEST.md"
    rm -f "$oldzip" "$oldman" || true
  done
fi

echo "[OK] Manifest: $MANIFEST"
echo "[OK] Upload the ZIP to Copilot for review."
