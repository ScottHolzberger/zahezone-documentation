#!/usr/bin/env python3
import argparse
import pathlib
import re
import sys

HEADER_RE = re.compile(r"^<!--\s*\nAuthoritative runtime document\.\s*\nIf it’s not described here, it’s not supported\.\s*\n-->\s*\n", re.M)

REQUIRED_SECTIONS = [
    r"^##\s+1\)\s+Purpose\s*$",
    r"^##\s+2\)\s+Scope\s*/\s*Responsibilities\s*$",
    r"^##\s+3\)\s+Runtime\s+Architecture\s*$",
    r"^##\s+4\)\s+Dependencies\s*$",
    r"^##\s+5\)\s+Data\s*/\s*Storage\s*$",
    r"^##\s+6\)\s+Operational\s+Lifecycle\s*$",
    r"^##\s+7\)\s+Validation\s+Checklist\s*$",
    r"^##\s+8\)\s+Failure\s+Modes\s*&\s+Recovery\s*$",
    r"^##\s+9\)\s+Change\s+Log\s*$",
]

SECTION_RES = [re.compile(p, re.M) for p in REQUIRED_SECTIONS]


def check_file(path: pathlib.Path, require_header=True, require_sections=True):
    txt = path.read_text(encoding='utf-8', errors='replace')
    problems = []

    if require_header and not HEADER_RE.search(txt[:3000]):
        problems.append("missing authoritative header comment")

    if require_sections:
        for i, rx in enumerate(SECTION_RES, start=1):
            if not rx.search(txt):
                problems.append(f"missing required section heading: {REQUIRED_SECTIONS[i-1]}")

    return problems


def iter_runbooks(root: pathlib.Path):
    # Only treat docs under runbooks/ as runbooks.
    for p in root.rglob('*.md'):
        if 'runbooks' in p.parts and p.name.endswith('_runbook.md'):
            yield p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default='.', help='repo root')
    ap.add_argument('--mode', choices=['all','changed'], default='all')
    ap.add_argument('--changed-files', default='', help='newline-separated list')
    args = ap.parse_args()

    root = pathlib.Path(args.root).resolve()

    if args.mode == 'changed':
        files = [pathlib.Path(f) for f in args.changed_files.splitlines() if f.strip()]
        paths = [ (root / f).resolve() for f in files if f.suffix.lower()=='.md' and 'runbooks' in f.parts and f.name.endswith('_runbook.md') ]
    else:
        paths = list(iter_runbooks(root))

    bad = 0
    for p in sorted(set(paths)):
        if not p.exists():
            continue
        problems = check_file(p)
        if problems:
            bad += 1
            print(f"FAIL: {p}")
            for pr in problems:
                print(f"  - {pr}")

    if bad:
        print(f"\nRunbook compliance failures: {bad}")
        sys.exit(2)

    print("Runbook compliance: OK")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
