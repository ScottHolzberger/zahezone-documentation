#!/usr/bin/env bash
set -euo pipefail

# Configure repo to use versioned hooks
# This ensures the pre-commit hook is shared with the team.

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit

echo "[OK] core.hooksPath set to .githooks"
