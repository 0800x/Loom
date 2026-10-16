#!/usr/bin/env python3
"""Fail-fast repository hygiene checks usable before Flutter is installed."""
from __future__ import annotations
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
errors: list[str] = []

FORBIDDEN_TEXT_PATTERNS = {
    r'continue-on-error\s*:\s*true': 'critical CI must not continue on error',
    r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----': 'private key material',
    r'AKIA[0-9A-Z]{16}': 'AWS access key-like token',
}

for path in ROOT.rglob('*'):
    if not path.is_file() or any(part in path.parts for part in {'.git', 'node_modules', '.dart_tool', 'build', 'target', '__pycache__'}):
        continue
    if path.suffix in {'.dart', '.yaml', '.yml', '.json', '.ts', '.sh', '.ps1', '.md'} or path.name in {'.gitignore', '.editorconfig'}:
        try:
            text = path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            continue
        for pattern, reason in FORBIDDEN_TEXT_PATTERNS.items():
            if 'continue-on-error' in pattern and '.github' not in path.parts:
                continue
            if re.search(pattern, text):
                errors.append(f'{path.relative_to(ROOT)}: {reason}')

for pubspec in ROOT.rglob('pubspec.yaml'):
    text = pubspec.read_text(encoding='utf-8')
    for match in re.finditer(r'^\s+path:\s*(.+?)\s*$', text, re.MULTILINE):
        target = (pubspec.parent / match.group(1).strip().strip('"\'')).resolve()
        if not target.exists():
            errors.append(f'{pubspec.relative_to(ROOT)}: missing path dependency {target}')

for package_json in ROOT.rglob('package.json'):
    try:
        json.loads(package_json.read_text(encoding='utf-8'))
    except Exception as exc:
        errors.append(f'{package_json.relative_to(ROOT)}: invalid JSON: {exc}')

if errors:
    print('Repository audit FAILED')
    for error in errors:
        print(f'- {error}')
    sys.exit(1)
print('Repository audit passed')
