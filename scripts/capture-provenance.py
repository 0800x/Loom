#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import sys
import subprocess
import release

directory = Path(sys.argv[1])
files = sorted(directory.glob('*.png'))
if not files: raise ValueError('No capture outputs')
entries = []
flutter = json.loads(subprocess.check_output(['flutter', '--version', '--machine'], text=True))
widget_tools = {'flutter': flutter['frameworkVersion'], 'dart': flutter['dartSdkVersion']}
for p in files:
    renderer = 'Bubble Tea v2 PTY capture rendered by xterm/Pillow' if p.name.startswith('tui-') else 'Chromium native browser capture' if p.name.startswith('node-') else 'Flutter production-widget render'
    metadata = directory / ('tui-renderer.json' if p.name.startswith('tui-') else 'node-renderer.json')
    tools = json.loads(metadata.read_text()) if p.name.startswith(('tui-', 'node-')) else widget_tools
    entries.append({'file': p.name, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
        'renderer': renderer, 'fixture': 'fictional; no real account, node or conversation',
        'toolchains': tools,
        'nativeDeviceIntegration': False, 'visuallyReviewed': False})
out = {'captureRevision': release.git('rev-parse', 'HEAD'),
       'captureSourceTree': release.git('write-tree'),
       'locale': 'en', 'images': entries,
       'note': 'Visual-review flags must be updated only after inspecting every image. Playback state is mocked; widget rendering does not verify native playback.'}
(directory / 'provenance.json').write_text(json.dumps(out, indent=2) + '\n')
