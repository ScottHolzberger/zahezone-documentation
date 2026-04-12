#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$ROOT/templates/runbook_template.md"
DATE="$(date +%Y-%m-%d)"

header='<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->'

REQ=(
"## 1) Purpose"
"## 2) Scope / Responsibilities"
"## 3) Runtime Architecture"
"## 4) Dependencies"
"## 5) Data / Storage"
"## 6) Operational Lifecycle"
"## 7) Validation Checklist"
"## 8) Failure Modes & Recovery"
"## 9) Change Log"
)

shopt -s nullglob
files=("$ROOT/runbooks"/*/*_runbook.md)

for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue

  # Ensure header exists
  if ! head -n 5 "$f" | grep -q "Authoritative runtime document"; then
    tmp="$(mktemp)"
    printf "%s\n\n" "$header" > "$tmp"
    cat "$f" >> "$tmp"
    mv "$tmp" "$f"
  fi

  # Check missing headings
  missing=0
  for h in "${REQ[@]}"; do
    if ! grep -qxF "$h" "$f"; then
      missing=1
      break
    fi
  done

  # If missing, inject skeleton and preserve existing content
  if [[ $missing -eq 1 ]]; then
    comp="$(basename "$(dirname "$f")")"
    tmp="$(mktemp)"

    # header + first H1 from existing file
    awk '{print} /^# /{exit}' "$f" > "$tmp"
    echo >> "$tmp"
    echo "---" >> "$tmp"
    echo >> "$tmp"

    # append template body (everything after template H1)
    awk 'seen{print} /^# /{seen=1}' "$TPL" \
      | sed -e "s/{{MODULE}}/$comp/g" -e "s/{{CLASSIFICATION}}/INFRA/g" -e "s/{{DATE}}/$DATE/g" \
      >> "$tmp"

    echo >> "$tmp"
    echo "---" >> "$tmp"
    echo >> "$tmp"
    echo "## Appendix: Legacy content" >> "$tmp"
    echo >> "$tmp"

    # original content after first H1
    awk 'start{print} /^# /{start=1; next}' "$f" >> "$tmp"

    mv "$tmp" "$f"
  fi
done

echo "[OK] Normalized all *_runbook.md files"
