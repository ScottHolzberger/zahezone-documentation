# ZaheZone Documentation Make targets
# Usage:
#   make copilot-export
#

.PHONY: copilot-export index runbook-check

index:
	python3 scripts/generate_toc.py --docs-root . --out INDEX.md

runbook-check:
	python3 scripts/check_runbooks.py --root . --mode all

copilot-export: index runbook-check
	./scripts/export_copilot_pack.sh
