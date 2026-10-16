"""Scan actual artifact payloads, including archive members, without extracting them.
First-party build paths,
signing files, generated local configuration and private donation URLs fail closed.
"""
import io
import json
import os
from pathlib import Path
import re
import sys
import tarfile
import zipfile
import release

directory = Path(sys.argv[1])
findings = []
blocked = []
build_roots = {str(release.ROOT)}
if os.getenv('GITHUB_WORKSPACE'): build_roots.add(os.environ['GITHUB_WORKSPACE'])
# Dart URIs use forward slashes even in Windows binaries. Native resources can
# use UTF-16, so neither representation may escape the same payload check.
variants = {variant for root in build_roots
            for variant in (root, root.replace('\\', '/'), root.replace('/', '\\'))}
prefixes = {variant.encode(encoding) for variant in variants
            for encoding in ('utf-8', 'utf-16-le')}

def scan(name, data):
    if Path(name).name in ('key.properties', 'local.properties', '.env') or name.lower().endswith(('.jks', '.keystore', '.pdb')):
        blocked.append({'file': name, 'reason': 'local configuration/signing/debug-symbol file'})
    if any(prefix in data for prefix in prefixes):
        blocked.append({'file': name, 'reason': 'unmapped first-party build path'})
    if re.search(rb'nowpayments[^\s"\']{0,200}api_key=', data):
        blocked.append({'file': name, 'reason': 'private donation URL'})
    for kind, expression in [
        ('other-build-path-to-review', rb'(?<![\w./])(?:C:\\Users\\[^\\\s"\']+\\|/Users/[^/\s"\']+/|/home/[^/\s"\']+/)'),
    ]:
        count = len(list(re.finditer(expression, data)))
        if count: findings.append({'file': name, 'kind': kind, 'count': count})

for path in sorted(directory.iterdir()):
    if not path.is_file() or path.suffix in ('.json',) or path.name == 'SHA256SUMS': continue
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if not name.endswith('/'): scan(path.name+'!'+name, z.read(name))
    elif tarfile.is_tarfile(path):
        with tarfile.open(path) as archive:
            for entry in archive:
                if entry.isfile(): scan(path.name+'!'+entry.name, archive.extractfile(entry).read())
    else: scan(path.name, path.read_bytes())
(directory / 'identity-audit.json').write_text(json.dumps({'findings':findings,'blocked':blocked,
    'anonymityGuaranteed':False,'scope':'actual artifact bytes and archive payloads'},indent=2)+'\n')
if blocked:
    for entry in blocked:
        print('Blocked artifact member: ' + entry['file'] + ' (' + entry['reason'] + ')', file=sys.stderr)
    raise ValueError('Artifact identity audit failed; inspect identity-audit.json')
print('Artifact payload identity audit passed')
