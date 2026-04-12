#!/usr/bin/env bash
set -euo pipefail

# normalize_runbooks.sh
# Ensures every runbook under runbooks/<component>/*.md has:
# - authoritative header
# - required section headings (exact strings)
# If a runbook is missing headings, inserts the standard skeleton after the first H1.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNBOOKS="$ROOT/runbooks"
TEMPLATE="$ROOT/templates/runbook_template.md"
DATE="$(date +%Y-%m-%d)"

REQ_HEADINGS=(
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

header_block='<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->'

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: missing template $TEMPLATE"
  exit 2
fi

shopt -s nullglob
files=("$RUNBOOKS"/*/*.md)

for f in "${files[@]}"; do
  # Skip non-files
  [[ -f "$f" ]] || continue

  tmp="$(mktemp)"
  txt="$(cat "$f")"

  # Ensure authoritative header at top
  if ! head -n 5 "$f" | grep -q "Authoritative runtime document"; then
    printf "%s\n\n" "$header_block" > "$tmp"
    cat "$f" >> "$tmp"
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi

  # Check if required headings exist
  missing=0
  for h in "${REQ_HEADINGS[@]}"; do
    if ! grep -qxF "$h" "$f"; then
      missing=1
      break
    fi
  done

  if [[ $missing -eq 1 ]]; then
    # Insert skeleton after the first H1 title line.
    # Preserve existing content by pushing it into an Appendix section.
    tmp="$(mktemp)"

    # capture module name from path
    comp="$(basename "$(dirname "$f")")"
    mod="${comp}"

    # Build skeleton from template
    skeleton="$(sed -e "s/{{MODULE}}/$mod/g" -e "s/{{CLASSIFICATION}}/INFRA/g" -e "s/{{DATE}}/$DATE/g" "$TEMPLATE")"

    # Keep existing file content (including header) but ensure skeleton headings exist.
    # Strategy:
    # - Extract header + first H1 from existing
    # - Add required skeleton sections
    # - Append original content under "Appendix: Legacy content" (so nothing is lost)

    # Get header + first title
    # Print up to first H1 line inclusive
    awk 'BEGIN{h=1} {print} /^# /{exit}' "$f" > "$tmp"

    # Add skeleton sections (skip header + H1 from template)
    echo >> "$tmp"
    echo "---" >> "$tmp"
    echo >> "$tmp"

    # From template, output everything after the first H1 line
    awk 'seen==1{print} /^# /{seen=1}' "$TEMPLATE" \
      | sed -e "s/{{MODULE}}/$mod/g" -e "s/{{CLASSIFICATION}}/INFRA/g" -e "s/{{DATE}}/$DATE/g" \
      >> "$tmp"

    echo >> "$tmp"
    echo "---" >> "$tmp"
    echo >> "$tmp"
    echo "## Appendix: Legacy content" >> "$tmp"
    echo >> "$tmp"

    # Append original full content after first H1 (to preserve any existing notes)
    awk 'start==1{print} /^# /{start=1; next}' "$f" >> "$tmp"

    mv "$tmp" "$f"
  fi

done

echo "[OK] Normalized runbooks under $RUNBOOKS"
