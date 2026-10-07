"""Local configuration creation, preservation, and missing-file handling."""
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        for path in ROOT.glob('*.sh'):
            shutil.copy2(path, self.base / path.name)
        shutil.copy2(ROOT / 'config.sh.example', self.base / 'config.sh.example')
        self.config = self.base / 'config.sh'

    def run_script(self, name='setup.sh', *args):
        return subprocess.run(['bash', str(self.base / name), *args], capture_output=True, text=True)

    def test_initialization_copies_example_with_private_permissions(self):
        result = self.run_script('setup.sh', '--init-config')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_bytes(), (self.base / 'config.sh.example').read_bytes())
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)

    def test_existing_settings_are_not_overwritten(self):
        original = b'SERVER_USER="custom-user"\n# private settings\n'
        self.config.write_bytes(original)
        before = self.config.stat().st_mtime_ns
        for _ in range(2):
            result = self.run_script('setup.sh', '--init-config')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.config.read_bytes(), original)
            self.assertEqual(self.config.stat().st_mtime_ns, before)

    def test_init_preserves_symlink_configuration(self):
        target = self.base / 'external-settings'
        target.write_text('# existing external config\n')
        self.config.symlink_to(target)
        result = self.run_script('setup.sh', '--init-config')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.config.is_symlink())
        self.assertEqual(target.read_text(), '# existing external config\n')

    def test_first_setup_creates_config_and_stops_before_system_actions(self):
        result = self.run_script('setup.sh', '--install-dependencies')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.config.is_file())
        self.assertIn('Edit config.sh, then rerun', result.stdout)
        self.assertNotIn('Installing required packages', result.stdout)

    def test_check_and_upgrade_do_not_generate_defaults_for_existing_installations(self):
        for option in ('--check', '--upgrade', '--upgrade --install-dependencies'):
            result = self.run_script('setup.sh', *option.split())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('--init-config', result.stderr)
            self.assertFalse(self.config.exists())
            self.assertNotIn('Installing required packages', result.stdout)

    def test_runtime_scripts_report_missing_local_config(self):
        for name in ('start-server.sh', 'stop-server.sh', 'update-server.sh', 'server-manager.sh', 'check-version.sh'):
            with self.subTest(script=name):
                result = self.run_script(name)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Missing local config.sh', result.stderr)
                self.assertIn('--init-config', result.stderr)
                self.assertFalse(self.config.exists())

    def test_help_does_not_need_or_create_local_config(self):
        result = self.run_script('setup.sh', '--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--init-config', result.stdout)
        self.assertFalse(self.config.exists())

    def test_missing_example_does_not_create_empty_config(self):
        (self.base / 'config.sh.example').unlink()
        result = self.run_script('setup.sh', '--init-config')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing config.sh.example', result.stderr)
        self.assertFalse(self.config.exists())


if __name__ == '__main__':
    unittest.main()
