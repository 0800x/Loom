import tempfile
import unittest
from pathlib import Path
from notice_sources import notice_files


class NoticeSourcesTest(unittest.TestCase):
    def test_directory_notices_and_embedded_license(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'LICENSE').mkdir()
            for name in ['MIT.LICENSE', 'valgrind.h.LICENSE']:
                (root / 'LICENSE' / name).write_bytes(b'upstream\r\n')
            (root / 'README.md').write_text('Usage\n## License\nMIT terms\n')
            (root / 'AUTHORS').write_text('LICENSE:\nMIT terms\n')
            (root / 'node_modules').mkdir()
            (root / 'node_modules' / 'LICENSE').write_text('unrelated')
            self.assertEqual([p.relative_to(root).as_posix() for p in notice_files(root)],
                             ['AUTHORS', 'LICENSE/MIT.LICENSE', 'LICENSE/valgrind.h.LICENSE', 'README.md'])
            self.assertEqual((root / 'LICENSE/MIT.LICENSE').read_bytes(), b'upstream\r\n')

    def test_readme_without_license_is_not_a_notice(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'README.md').write_text('See the license elsewhere.')
            (root / 'LICENSE').symlink_to('/etc/hostname')
            self.assertEqual(notice_files(root), [])


if __name__ == '__main__':
    unittest.main()
