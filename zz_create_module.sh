#!/usr/bin/env bash
set -euo pipefail

# Usage: zz_create_module.sh <module-name>
# Example: zz_create_module.sh billing-portal

MODULE="${1:-}"
DOC_ROOT="/opt/Documentation"
RUNTIME_ROOT="/opt"
RUNBOOK_NAME="${MODULE}_runbook.md"

if [[ -z "$MODULE" ]]; then
  echo "Usage: $0 <module-name>"
  exit 1
fi

DOC_RUNBOOK_DIR="$DOC_ROOT/runbooks/$MODULE"
DOC_RUNBOOK="$DOC_RUNBOOK_DIR/$RUNBOOK_NAME"

RUNTIME_RUNBOOK_DIR="$RUNTIME_ROOT/$MODULE/runbooks"
RUNTIME_RUNBOOK="$RUNTIME_RUNBOOK_DIR/$RUNBOOK_NAME"

echo "[*] Creating Documentation authoring structure"
sudo mkdir -p "$DOC_RUNBOOK_DIR"
sudo chown -R zahezone:ops "$DOC_ROOT"
sudo chmod -R 2775 "$DOC_ROOT"

if [[ ! -f "$DOC_RUNBOOK" ]]; then
  cat <<EOF | sudo tee "$DOC_RUNBOOK" >/dev/null
<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# $MODULE — Authoritative Runbook

Component: $MODULE  
Classification: INFRA  
Authoritative runtime location: /opt/$MODULE  

## Purpose

Describe the purpose of this module.

## Architecture

Describe architecture.

## Operations

Describe operational steps.

## Validation

Describe validation steps.
EOF
fi

# *** IMPORTANT: make file VS Code writable ***
sudo chown zahezone:ops "$DOC_RUNBOOK"
sudo chmod 664 "$DOC_RUNBOOK"

echo "[*] Creating runtime runbooks directory"
sudo mkdir -p "$RUNTIME_RUNBOOK_DIR"

# Backup any existing runbook
if [[ -e "$RUNTIME_RUNBOOK" && ! -L "$RUNTIME_RUNBOOK" ]]; then
  sudo mv "$RUNTIME_RUNBOOK" "${RUNTIME_RUNBOOK}.pre_module_migration.bak"
fi

if [[ ! -L "$RUNTIME_RUNBOOK" ]]; then
  sudo ln -s "$DOC_RUNBOOK" "$RUNTIME_RUNBOOK"
fi

echo "[*] Adding to Documentation Git repo"
cd "$DOC_ROOT"
git add "runbooks/$MODULE"
git commit -m "Add runbook template for $MODULE" || true

echo "[OK] Module '$MODULE' created and compliant."