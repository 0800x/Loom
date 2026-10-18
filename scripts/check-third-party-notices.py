#!/usr/bin/env python3
"""Check preserved upstream notice bytes without changing the inventory."""
import hashlib, json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
items=json.loads((root/'third_party/dependency-inventory.json').read_text())
for p in (root/'third_party/licenses').glob('*.txt'):
    assert hashlib.sha256(p.read_bytes()).hexdigest()==p.stem, str(p)
for item in items:
    assert item['texts'], f"Missing notice: {item['name']}@{item['version']}"
    for notice in item['texts']:
        p=Path(notice['file'])
        assert p.parent==Path('third_party/licenses') and (root/p).is_file(), str(p)
print(f"Verified {len(items)} inventory entries and preserved notice digests")
