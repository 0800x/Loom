"""Guard the real application package name and generated-URI preparation."""
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native_config', ROOT / 'scripts/prepare-native-package-config.py')
native_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native_config)


class NativePackageConfig(unittest.TestCase):
    def fixture(self, folder):
        app = Path(folder)
        config = app / '.dart_tool/package_config.json'
        config.parent.mkdir()
        name = re.search(r'^name:\s*(\w+)', (ROOT / 'apps/loom/pubspec.yaml').read_text(), re.M).group(1)
        data = {'configVersion': 2, 'packages': [
            {'name': name, 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.12'},
            {'name': 'plugin_fixture', 'rootUri': 'file:///fixture/plugin/', 'packageUri': 'lib/'}]}
        config.write_text(json.dumps(data))
        return app, config, data

    def test_actual_application_gets_stable_alias_without_changing_dependencies(self):
        with tempfile.TemporaryDirectory() as folder:
            app, config, original = self.fixture(folder)
            native_config.prepare(app)
            result = json.loads(config.read_text())
            self.assertEqual(result['packages'][:-1], original['packages'])
            self.assertEqual(result['packages'][-1], {'name': native_config.ALIAS,
                             'rootUri': 'flutter_build/', 'packageUri': '', 'languageVersion': '3.12'})
            first = config.read_bytes()
            native_config.prepare(app)
            self.assertEqual(config.read_bytes(), first)

    def test_alias_collision_fails_without_mutating_config(self):
        with tempfile.TemporaryDirectory() as folder:
            app, config, original = self.fixture(folder)
            original['packages'].append({'name': native_config.ALIAS, 'rootUri': 'file:///other/'})
            config.write_text(json.dumps(original))
            first = config.read_bytes()
            with self.assertRaisesRegex(ValueError, 'already in use'):
                native_config.prepare(app)
            self.assertEqual(config.read_bytes(), first)


if __name__ == '__main__':
    unittest.main()
