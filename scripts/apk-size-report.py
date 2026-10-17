#!/usr/bin/env python3
"""Report APK compressed payload by ABI and category; never modifies the APK."""
import argparse
import collections
import json
from pathlib import Path
import zipfile


def report(path):
    groups = collections.defaultdict(lambda: {'compressed_bytes': 0, 'uncompressed_bytes': 0, 'files': 0})
    largest = []
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            if item.is_dir():
                continue
            parts = item.filename.split('/')
            if parts[0] == 'lib' and len(parts) > 2:
                group = f'native/{parts[1]}'
            elif parts[:2] == ['assets', 'flutter_assets']:
                group = 'flutter-assets'
            elif item.filename.endswith('.dex'):
                group = 'dex'
            else:
                group = 'resources-and-metadata'
            row = groups[group]
            row['compressed_bytes'] += item.compress_size
            row['uncompressed_bytes'] += item.file_size
            row['files'] += 1
            largest.append({'path': item.filename, 'compressed_bytes': item.compress_size,
                            'uncompressed_bytes': item.file_size})
    return {'apk': path.name, 'apk_bytes': path.stat().st_size, 'groups': dict(sorted(groups.items())),
            'largest_entries': sorted(largest, key=lambda x: x['compressed_bytes'], reverse=True)[:30]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apks', type=Path, nargs='+')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = [report(path) for path in args.apks]
    for apk in result:
        print(f"{apk['apk']}: {apk['apk_bytes'] / 1048576:.2f} MiB")
        for name, group in apk['groups'].items():
            print(f"  {name}: {group['compressed_bytes'] / 1048576:.2f} MiB compressed")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
