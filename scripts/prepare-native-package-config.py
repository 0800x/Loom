"""Give Flutter's generated Dart registrant a stable package URI.

Run after pub get, then build with --no-pub. Flutter's compiler resolves --source
and flutter.dart_plugin_registrant through this same package_config entry. No
SDK, generated registrant, compiled bytes or dependency lockfile is rewritten.
"""
import json
from pathlib import Path
import sys

ALIAS = 'loom_generated_registrant'


def prepare(app):
    config = Path(app) / '.dart_tool/package_config.json'
    data = json.loads(config.read_text())
    if data.get('configVersion') != 2:
        raise ValueError('Expected Dart package configuration version 2')
    packages = data['packages']
    application = next(p for p in packages if p['name'] == 'loom_next')
    alias = {'name': ALIAS, 'rootUri': 'flutter_build/', 'packageUri': '',
             'languageVersion': application['languageVersion']}
    existing = [p for p in packages if p['name'] == ALIAS]
    if existing and existing != [alias]:
        raise ValueError('Generated registrant package name is already in use')
    (config.parent / 'flutter_build').mkdir(exist_ok=True)
    if not existing:
        packages.append(alias)
        config.write_text(json.dumps(data, indent=2) + '\n')
    print('Generated registrant uses package:loom_generated_registrant/')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]) if len(sys.argv) > 1 else Path('apps/loom'))
