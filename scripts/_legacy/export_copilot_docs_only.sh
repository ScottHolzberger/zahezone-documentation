#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
OUT_DIR="$ROOT/exports/docs_only"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_ZIP="$OUT_DIR/docs_only_copilot_${TS}.zip"

mkdir -p "$OUT_DIR"

python3 scripts/generate_toc.py --docs-root "$ROOT" --out INDEX.md >/dev/null || true

zip -r "$OUT_ZIP" \
  README.md \
  INDEX.md \
  runbooks \
  exports/*MANIFEST.md \
  -i '*_runbook.md' \
  -x '*.sh' '*.py' '.git/*' 'scripts/*' '.github/*'

echo "[OK] Created sanitized Copilot docs-only export:"
echo "     $OUT_ZIP"