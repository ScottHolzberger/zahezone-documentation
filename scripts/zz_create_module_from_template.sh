#!/usr/bin/env bash
set -euo pipefail

# zz_create_module_from_template.sh
# Creates a new module runbook seeded from templates/runbook_template.md
# and ensures runtime symlink exists under /opt/<module>/runbooks.
# Designed for the Documentation authoring repo at /opt/Documentation.

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <module-name> [classification]"
  echo "Example: $0 manage-cfg-sync-pbx INFRA"
  exit 1
fi

MODULE="$1"
CLASSIFICATION="${2:-INFRA}"
DOC_ROOT="/opt/Documentation"
TPL="$DOC_ROOT/templates/runbook_template.md"
DATE="$(date +%Y-%m-%d)"

DOC_DIR="$DOC_ROOT/runbooks/$MODULE"
DOC_FILE="$DOC_DIR/${MODULE}_runbook.md"
RUNTIME_DIR="/opt/$MODULE/runbooks"
RUNTIME_FILE="$RUNTIME_DIR/${MODULE}_runbook.md"

if [[ ! -f "$TPL" ]]; then
  echo "ERROR: template missing: $TPL"
  echo "Make sure templates/runbook_template.md exists in /opt/Documentation"
  exit 2
fi

sudo mkdir -p "$DOC_DIR"

# Seed runbook from template if it doesn't exist
if [[ ! -f "$DOC_FILE" ]]; then
  sed \
    -e "s/{{MODULE}}/$MODULE/g" \
    -e "s/{{CLASSIFICATION}}/$CLASSIFICATION/g" \
    -e "s/{{DATE}}/$DATE/g" \
    "$TPL" | sudo tee "$DOC_FILE" >/dev/null

  # Ensure VS Code can edit
  sudo chown zahezone:ops "$DOC_FILE" || true
  sudo chmod 664 "$DOC_FILE" || true
else
  echo "NOTE: runbook already exists: $DOC_FILE"
fi

# Ensure runtime runbooks dir exists and is linked back to Documentation
sudo mkdir -p "$RUNTIME_DIR"

# Backup any existing non-symlink runtime file
if [[ -e "$RUNTIME_FILE" && ! -L "$RUNTIME_FILE" ]]; then
  sudo mv "$RUNTIME_FILE" "${RUNTIME_FILE}.pre_symlink.bak.$(date +%Y%m%d_%H%M%S)"
fi

# Create/replace symlink
if [[ -L "$RUNTIME_FILE" ]]; then
  sudo rm -f "$RUNTIME_FILE"
fi
sudo ln -s "$DOC_FILE" "$RUNTIME_FILE"

# Refresh INDEX.md
python3 "$DOC_ROOT/scripts/generate_toc.py" --docs-root "$DOC_ROOT" --out INDEX.md >/dev/null || true

echo "[OK] Module created: $MODULE"
echo "     Authoring: $DOC_FILE"
echo "     Runtime symlink: $RUNTIME_FILE"
