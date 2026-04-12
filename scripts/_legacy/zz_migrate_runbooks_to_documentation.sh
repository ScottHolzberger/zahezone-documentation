#!/usr/bin/env bash
set -euo pipefail

# zz_migrate_runbooks_to_documentation.sh
# Centralise .md runbooks into /opt/Documentation and replace originals with symlinks.
# Safe: copies files, backs up originals, then symlinks.
# Use --dry-run to preview.

DOC_ROOT="/opt/Documentation"
SEARCH_ROOT="/opt"
DRY_RUN=0

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

TS="$(date +%Y%m%d_%H%M%S)"
REPORT="$DOC_ROOT/migration_report_${TS}.md"

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY] $*"
  else
    "$@"
  fi
}

ensure_doc_root() {
  run sudo mkdir -p "$DOC_ROOT/runbooks"
  run sudo chown -R zahezone:ops "$DOC_ROOT"
  run sudo chmod -R 2775 "$DOC_ROOT"
}

collect_runbooks() {
  find "$SEARCH_ROOT" \
    \( -path "$DOC_ROOT" -o -path "$DOC_ROOT/*" \) -prune -o \
    \( -path "*/.git" -o -path "*/.git/*" \) -prune -o \
    \( -path "*/zahezone-system-audit/*" \) -prune -o \
    \( -path "*/_quarantine_*" -o -path "*/_quarantine_*/*" \) -prune -o \
    -type f \
    -path "*/runbooks/*.md" \
    -print
}


component_name() {
  if [[ "$1" =~ ^/opt/([^/]+)/runbooks/ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "misc"
  fi
}

migrate_one() {
  local src="$1"
  local comp
  comp="$(component_name "$src")"
  local base
  base="$(basename "$src")"

  local dest_dir="$DOC_ROOT/runbooks/$comp"
  local dest="$dest_dir/$base"

  run sudo mkdir -p "$dest_dir"

  if [[ -e "$dest" ]]; then
    dest="$dest_dir/${base%.md}__${TS}.md"
  fi

  run sudo cp -a "$src" "$dest"

  if [[ ! -L "$src" ]]; then
    run sudo mv "$src" "${src}.pre_migration_${TS}.bak"
  else
    run sudo rm -f "$src"
  fi

  run sudo ln -s "$dest" "$src"

  echo "| $src | $dest | migrated |" >> "$REPORT"
}

ensure_doc_root

if [[ "$DRY_RUN" -eq 0 ]]; then
  cat > "$REPORT" <<EOF
<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# Runbook Migration Report
Generated: $(date)

| Source | Destination | Action |
|--------|-------------|--------|
EOF
fi

mapfile -t FILES < <(collect_runbooks)

echo "Found ${#FILES[@]} runbook files"

for f in "${FILES[@]}"; do
  migrate_one "$f"
done

echo "Done."
echo "Report: $REPORT"