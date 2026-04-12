#!/usr/bin/env bash
set -euo pipefail

# zz_one_command_audit_export.sh
# Single-command update + auditability workflow for /opt/Documentation.
# What it does:
# 1) Pull latest from origin/main (if repo has origin)
# 2) Normalize runbooks (ensures header + required headings)
# 3) Generate INDEX.md (TOC)
# 4) Run compliance check
# 5) Commit + push changes (if any)
# 6) Produce Copilot-friendly docs-only export ZIP + manifest
# 7) Prune old exports

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${ROOT}" ]]; then
  echo "ERROR: must be run inside a git repo (expected /opt/Documentation)"
  exit 2
fi
cd "$ROOT"

REPO_NAME="$(basename "$ROOT")"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
REMOTE_URL="$(git remote get-url origin 2>/dev/null || echo 'N/A')"
TS="$(date +%Y%m%d_%H%M%S)"

PRUNE_DAYS="${PRUNE_DAYS:-14}"
PRUNE_KEEP="${PRUNE_KEEP:-30}"

EXPORT_DIR="$ROOT/exports"
mkdir -p "$EXPORT_DIR"

log() { echo "[zz] $*"; }

# 1) Pull latest (best effort)
if git remote get-url origin >/dev/null 2>&1; then
  log "Fetching latest from origin"
  git fetch origin >/dev/null 2>&1 || true
  git pull --rebase origin main >/dev/null 2>&1 || true
fi

# 2) Normalize runbooks (best effort)
if [[ -x "$ROOT/scripts/normalize_runbooks_strict.sh" ]]; then
  log "Normalizing runbooks (strict)"
  "$ROOT/scripts/normalize_runbooks_strict.sh" || true
elif [[ -x "$ROOT/scripts/normalize_runbooks.sh" ]]; then
  log "Normalizing runbooks"
  "$ROOT/scripts/normalize_runbooks.sh" || true
else
  log "No normalizer found; skipping normalize step"
fi

# 3) Generate INDEX.md
if [[ -f "$ROOT/scripts/generate_toc.py" ]]; then
  log "Generating INDEX.md"
  python3 "$ROOT/scripts/generate_toc.py" --docs-root "$ROOT" --out INDEX.md >/dev/null
else
  log "Missing scripts/generate_toc.py; cannot generate INDEX.md"
  exit 3
fi

# 4) Compliance check (hard fail)
if [[ -f "$ROOT/scripts/check_runbooks.py" ]]; then
  log "Running runbook compliance"
  python3 "$ROOT/scripts/check_runbooks.py" --root "$ROOT" --mode all
else
  log "Missing scripts/check_runbooks.py; cannot run compliance"
  exit 4
fi

# 5) Rebase, then commit + push (only if changes)
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "Staging changes"
  git add -A

  log "Rebasing on origin/${BRANCH}"
  git fetch origin >/dev/null 2>&1 || true
  git pull --rebase origin "${BRANCH}" >/dev/null 2>&1 || true

  if ! git diff --cached --quiet; then
    log "Committing changes"
    git commit -m "chore: docs normalize + INDEX refresh (${TS})" --no-verify >/dev/null || true
  fi

  log "Pushing to origin/${BRANCH}"
  git push >/dev/null 2>&1 || true
else
  log "No changes to commit"
fi

# Refresh metadata after possible commit
GIT_HEAD="$(git rev-parse HEAD 2>/dev/null || echo 'N/A')"

# 6) Create docs-only Copilot export ZIP + manifest
OUT_ZIP="$EXPORT_DIR/${REPO_NAME}_docs_only_copilot_${TS}.zip"
MANIFEST="$EXPORT_DIR/${REPO_NAME}_docs_only_copilot_${TS}_MANIFEST.md"

cat > "$MANIFEST" <<EOF
<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# Copilot Docs-Only Review Package Manifest

Generated: $(date)
Repository: $REPO_NAME
Repository URL: $REMOTE_URL
Branch: $BRANCH
Git HEAD: $GIT_HEAD

Included:
- README.md (if present)
- INDEX.md (if present)
- runbooks/**/_runbook.md

Excluded:
- scripts/**
- templates/**
- .github/**
- .git/**
- exports/** (previous exports)
EOF

log "Creating docs-only ZIP export"
python3 <<PY
from pathlib import Path
import zipfile

root = Path("$ROOT")
out_zip = Path("$OUT_ZIP")
manifest = Path("$MANIFEST")

with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as z:
    # Optional top-level docs
    for rel in ["README.md", "INDEX.md"]:
        p = root / rel
        if p.exists():
            z.write(p, p.relative_to(root))

    # Only authoritative runbooks
    rb = root / "runbooks"
    if rb.exists():
        for f in rb.rglob("*_runbook.md"):
            if f.is_file():
                z.write(f, f.relative_to(root))

    if manifest.exists():
        z.write(manifest, manifest.relative_to(root))

print(out_zip)
PY

# 7) Prune old exports (age + count)
log "Pruning old exports (days>$PRUNE_DAYS, keep newest $PRUNE_KEEP)"
find "$EXPORT_DIR" -maxdepth 1 -type f \( -name '*_docs_only_copilot_*.zip' -o -name '*_docs_only_copilot_*_MANIFEST.md' \) -mtime +"$PRUNE_DAYS" -print -delete 2>/dev/null || true

mapfile -t zips < <(ls -1t "$EXPORT_DIR"/*_docs_only_copilot_*.zip 2>/dev/null || true)
if [[ ${#zips[@]} -gt $PRUNE_KEEP ]]; then
  for ((i=PRUNE_KEEP; i<${#zips[@]}; i++)); do
    oldzip="${zips[$i]}"
    oldman="${oldzip%.zip}_MANIFEST.md"
    rm -f "$oldzip" "$oldman" || true
  done
fi

log "DONE"
echo "ZIP:      $OUT_ZIP"
echo "MANIFEST: $MANIFEST"
echo "Upload ZIP to Copilot for review (docs-only)."

# --- Upload manifest to SharePoint for Copilot indexing ---

if command -v pwsh >/dev/null 2>&1; then
  log "Uploading review pack to SharePoint (Copilot-Manifests)"
  pwsh scripts/upload_reviewpack_to_sharepoint.ps1 \
  -PackRoot "$ROOT" \
  -PackStamp "$TS" \
  -ManifestPath "$MANIFEST"
else
  log "pwsh not installed – skipping SharePoint upload"
fi
