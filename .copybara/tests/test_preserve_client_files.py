import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'preserve_client_files.py'


class PreserveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.com')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root)

    def commit(self):
        self.git('add', '-A')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD').decode().strip()

    def guard(self, base, apply=False):
        return subprocess.run(['python3', str(SCRIPT), base, *(['--apply'] if apply else [])],
                              cwd=self.root, capture_output=True, text=True)

    def test_preserves_binary_modes_symlinks_and_source_deletion(self):
        for name in ['client only.bin', 'source-deleted.txt', 'old-name.txt']:
            (self.root / name).write_bytes(b'\x00original\xff')
        (self.root / 'client only.bin').chmod(0o755)
        (self.root / 'client-link').symlink_to('client only.bin')
        base = self.commit()
        for name in ['client only.bin', 'source-deleted.txt', 'client-link']:
            (self.root / name).unlink()
        (self.root / 'old-name.txt').rename(self.root / 'new-name.txt')
        self.commit()
        self.assertEqual(self.guard(base).returncode, 1)
        result = self.guard(base, True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ['client only.bin', 'source-deleted.txt', 'old-name.txt']:
            self.assertEqual((self.root / name).read_bytes(), b'\x00original\xff')
        self.assertTrue(os.access(self.root / 'client only.bin', os.X_OK))
        self.assertTrue((self.root / 'client-link').is_symlink())
        self.assertTrue((self.root / 'new-name.txt').exists())
        self.commit()
        self.assertEqual(self.guard(base).returncode, 0)

    def test_path_collision_blocks_without_overwriting_source(self):
        (self.root / 'conflict').write_text('client data')
        base = self.commit()
        (self.root / 'conflict').unlink()
        (self.root / 'conflict').mkdir()
        (self.root / 'conflict/new.txt').write_text('source data')
        self.commit()
        self.assertNotEqual(self.guard(base, True).returncode, 0)
        self.assertEqual((self.root / 'conflict/new.txt').read_text(), 'source data')
        self.assertEqual(self.git('status', '--porcelain'), b'')


if __name__ == '__main__':
    unittest.main()
