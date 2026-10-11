#!/usr/bin/env python3
"""Package the actual project inputs; never include node_modules or Rust output."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import json

root = Path(__file__).resolve().parent.parent
version = json.loads((root / 'package.json').read_text())['version']
destination = root / 'artifacts' / f'NeatPaste-v{version}-source.zip'
destination.parent.mkdir(exist_ok=True)
excluded = {'node_modules', 'target', 'dist', 'artifacts', '.git', 'gen', '__pycache__'}
with ZipFile(destination, 'w', compression=ZIP_DEFLATED, compresslevel=9) as archive:
    for item in sorted(root.rglob('*')):
        relative = item.relative_to(root)
        if relative.parts[:2] == ('native', 'bin') or any(part in excluded for part in relative.parts):
            continue
        if not item.is_file() or item.is_symlink() or item.name == '.DS_Store' or item.name.startswith('.env') or item.suffix == '.log':
            continue
        archive.write(item, Path('neatpaste') / relative)
print(destination)
