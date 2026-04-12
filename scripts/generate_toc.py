#!/usr/bin/env python3
import argparse
import pathlib
from datetime import datetime


def title_from_md(path: pathlib.Path):
    try:
        for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
            if line.startswith('# '):
                return line[2:].strip()
    except Exception:
        pass
    return path.stem


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--docs-root', default='.', help='Documentation repo root')
    ap.add_argument('--out', default='INDEX.md', help='Output index file')
    args = ap.parse_args()

    root = pathlib.Path(args.docs_root).resolve()
    runbooks = root/'runbooks'

    items = []
    if runbooks.exists():
        for comp_dir in sorted([p for p in runbooks.iterdir() if p.is_dir()]):
            comp = comp_dir.name
            md_files = sorted(comp_dir.glob('*.md'))
            if not md_files:
                continue
            entries = []
            for f in md_files:
                rel = f.relative_to(root)
                entries.append((title_from_md(f), rel.as_posix()))
            items.append((comp, entries))

    out = root/args.out
    lines = []
    lines.append('<!--')
    lines.append('Authoritative runtime document.')
    lines.append('If it’s not described here, it’s not supported.')
    lines.append('-->')
    lines.append('')
    lines.append('# Documentation Index')
    lines.append('')
    lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append('')
    lines.append('## Runbooks')
    lines.append('')

    for comp, entries in items:
        lines.append(f"### {comp}")
        for title, rel in entries:
            lines.append(f"- [{title}]({rel})")
        lines.append('')

    out.write_text('\n'.join(lines).rstrip()+'\n', encoding='utf-8')
    print(f"Wrote {out}")


if __name__ == '__main__':
    main()
