import os
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch
import release


class BuildMetadata(unittest.TestCase):
    def test_version_command_resolves_path_and_windows_batch_extension(self):
        with tempfile.TemporaryDirectory(prefix='loom tools ') as folder:
            executable = Path(folder) / ('loom-version.cmd' if os.name == 'nt' else 'loom-version')
            executable.write_text('@echo off\r\necho fixture %1\r\n' if os.name == 'nt'
                                  else '#!/bin/sh\nprintf "fixture %s\\n" "$1"\n')
            executable.chmod(0o755)
            with patch.dict(os.environ, {'PATH': folder + os.pathsep + os.environ.get('PATH', '')}):
                self.assertEqual(release.toolchain_version('loom-version --version'), 'fixture --version')

    def test_missing_tool_fails_before_writing_manifest(self):
        with patch.dict(os.environ, {'PATH': ''}):
            with self.assertRaisesRegex(ValueError, 'executable unavailable'):
                release.toolchain_version('loom-nonexistent-tool --version')

    def test_runtime_report_removes_builder_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root / 'runtime.txt'
            raw = f'libloom.so => {root}/bundle/lib/libloom.so (0x123)\nlibc => /usr/lib/libc.so\n'
            with patch.object(release, 'ROOT', root), patch.dict(os.environ, {'GITHUB_WORKSPACE': str(root)}), \
                    patch.object(release.subprocess, 'check_output', return_value=raw):
                release.runtime_dependencies(root / 'bundle/loom', output)
            self.assertNotIn(str(root), output.read_text())
            self.assertIn('/loom/bundle/lib/libloom.so', output.read_text())
            self.assertIn('/usr/lib/libc.so', output.read_text())

    def test_missing_linux_library_still_blocks_report(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'runtime.txt'
            with patch.object(release.subprocess, 'check_output', return_value='libmpv.so => not found\n'):
                with self.assertRaisesRegex(ValueError, 'Missing Linux runtime dependency'):
                    release.runtime_dependencies(Path(folder) / 'loom', output)
            self.assertFalse(output.exists())

    def test_payload_audit_blocks_windows_path_representations(self):
        for value in ('D:/build/Loom/app/source.dart'.encode(),
                      'D:\\build\\Loom\\app\\source.dart'.encode(),
                      'D:/build/Loom/app/source.dart'.encode('utf-16-le')):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                (root / 'fixture.bin').write_bytes(value)
                environment = dict(os.environ, GITHUB_WORKSPACE='D:\\build\\Loom')
                result = subprocess.run([sys.executable, str(release.ROOT / 'scripts/audit-artifact.py'), folder],
                                        env=environment, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Blocked artifact member: fixture.bin', result.stderr)


if __name__ == '__main__':
    unittest.main()
