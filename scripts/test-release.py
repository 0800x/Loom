import os
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import release

def elf(machine):
    data = bytearray(64); data[:4] = b'\x7fELF'; data[5] = 1
    struct.pack_into('<H', data, 18, machine)
    return bytes(data)

class ReleaseSafety(unittest.TestCase):
    def test_source_repository_tag_cannot_build_release(self):
        with patch.dict(os.environ, {'GITHUB_REF_TYPE': 'tag', 'GITHUB_REPOSITORY': 'example/source'}, clear=True):
            with self.assertRaisesRegex(ValueError, 'only in 0800x/Loom'): release.preflight()

    def test_exact_tag_requires_revision_approval(self):
        with patch.dict(os.environ, {'GITHUB_REF_TYPE': 'tag', 'GITHUB_REPOSITORY': '0800x/Loom', 'GITHUB_REF_NAME': 'v0.1.0-alpha.1'}, clear=True):
            with self.assertRaisesRegex(ValueError, 'explicit approval'): release.preflight()

    def test_audit_accepts_feature_home_imports(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'source.dart').write_text("import 'features/home/presentation/shell.dart';\n")
            (root / 'updater.go').write_text('filepath.Glob("/home/*/Loom")')
            release.audit(root, root / 'audit.json')

    def test_audit_rejects_embedded_user_home(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'binary.txt').write_text('/home/' + 'exampleuser/private-project/source.rs')
            with self.assertRaisesRegex(ValueError, 'identifying paths'):
                release.audit(root, root / 'audit.json')

    def test_protocol_contract_rejects_a_foreign_namespace(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'release').mkdir()
            (root / 'source.txt').write_text('Foreign-Protocol-v1')
            (root / 'release/compatibility-contract.json').write_text(json.dumps({'source.txt': ['Foreign-Protocol-v1']}))
            with patch.object(release, 'ROOT', root):
                with self.assertRaisesRegex(ValueError, 'namespace contract'):
                    release.validate_protocol_contract()

    def test_protocol_contract_rejects_source_drift(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'release').mkdir()
            (root / 'source.txt').write_text('Loom-Other-v1')
            (root / 'release/compatibility-contract.json').write_text(json.dumps({'source.txt': ['Loom-Required-v1']}))
            with patch.object(release, 'ROOT', root):
                with self.assertRaisesRegex(ValueError, 'namespace contract'):
                    release.validate_protocol_contract()

    def test_missing_native_library_rejects_apk(self):
        with tempfile.TemporaryDirectory() as t:
            path = Path(t) / 'empty.apk'
            with zipfile.ZipFile(path, 'w'): pass
            with self.assertRaisesRegex(ValueError, 'MLS ABIs'): release.inspect_apk(path, ['arm64-v8a'])

    def test_mislabeled_abi_rejects_apk(self):
        with tempfile.TemporaryDirectory() as t:
            path = Path(t) / 'wrong.apk'
            with zipfile.ZipFile(path, 'w') as z:
                z.writestr('lib/arm64-v8a/libloom_mls.so', elf(62))
                z.writestr('lib/arm64-v8a/libflutter.so', elf(183))
            with self.assertRaisesRegex(ValueError, 'architecture mismatch'): release.inspect_apk(path, ['arm64-v8a'])

    def test_missing_flutter_runtime_rejects_apk(self):
        with tempfile.TemporaryDirectory() as t:
            path = Path(t) / 'partial.apk'
            with zipfile.ZipFile(path, 'w') as z: z.writestr('lib/x86_64/libloom_mls.so', elf(62))
            with self.assertRaisesRegex(ValueError, 'Flutter runtime'): release.inspect_apk(path, ['x86_64'])

if __name__ == '__main__': unittest.main()
