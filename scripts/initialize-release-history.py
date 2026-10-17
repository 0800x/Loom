#!/usr/bin/env python3
"""Prepare a reviewed two-commit release history locally; never push or touch tags."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def prepare(reviewed):
    def git(*args, data=None):
        return subprocess.check_output(['git', *args], input=data).decode().strip()
    if not re.fullmatch('[a-f0-9]{40}', reviewed):
        raise ValueError('An immutable reviewed revision is required')
    if git('remote', 'get-url', 'origin').rstrip('/') not in ('https://github.com/0800x/Loom.git', 'https://github.com/0800x/Loom'):
        raise ValueError('Only 0800x/Loom may initialize release history')
    request = '.github/clean-history-request.json'
    changed = git('diff', '--name-only', reviewed, 'HEAD').splitlines()
    if changed != [request]:
        raise ValueError('The initialization request must be the only change after review')
    if git('status', '--porcelain'):
        raise ValueError('Working tree must be clean')
    tree = git('rev-parse', reviewed+'^{tree}')
    initial = git('commit-tree', tree, data=b'Initial release\n')
    archive = subprocess.check_output(['git', 'archive', '--format=tar', initial])
    digest = hashlib.sha256(archive).hexdigest()
    helper = subprocess.check_output(['git', 'show', initial+':scripts/install-loom-node.sh'])
    pins = {
        'LOOM_INSTALL_REVISION': initial,
        'LOOM_INSTALL_ARCHIVE_SHA256': digest,
        'LOOM_INSTALL_BOOTSTRAP_SHA256': hashlib.sha256(helper).hexdigest(),
    }
    path = Path('install.sh')
    content = path.read_text()
    for key, value in pins.items():
        content, count = re.subn(r"^"+key+r"='[a-f0-9]+'$", key+"='"+value+"'", content, flags=re.M)
        if count != 1: raise ValueError('Missing/ambiguous installer pin: '+key)
    path.write_text(content)
    channel_path = Path('release/node-channel.json')
    channel = json.loads(channel_path.read_text())
    if channel['repository'] != '0800x/Loom' or channel['branch'] != 'main':
        raise ValueError('Unexpected publisher channel')
    channel.update(revision=initial, sha256=digest, sequence=channel['sequence']+1)
    channel_path.write_text(json.dumps(channel, indent=2)+'\n')
    git('rm', '--cached', '--', request)
    git('add', '--', 'install.sh', 'release/node-channel.json')
    final_tree = git('write-tree')
    final = git('commit-tree', final_tree, '-p', initial, data=b'Configure verified installer\n')
    if git('rev-list', '--count', final) != '2': raise ValueError('Unexpected release ancestry')
    if git('diff', '--name-only', initial, final).splitlines() != ['install.sh', 'release/node-channel.json']:
        raise ValueError('Unexpected source changes during initialization')
    return {'initialCommit': initial, 'head': final, 'sourceDigest': digest}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--reviewed-revision', required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.reviewed_revision)))
