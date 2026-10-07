"""Compatibility migration regressions using legacy installation fixtures."""
import importlib.util
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
q = shlex.quote
spec = importlib.util.spec_from_file_location('migration', ROOT / 'migrate-settings.py')
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class SettingsMigrationTests(unittest.TestCase):
    def test_only_legacy_screen_directives_change(self):
        before = 'defscrollback 25000\nmultiuser on\nacladd root\nacladd customuser\nbind x quit\n'
        after = migration.migrate_text(before, screen=True)
        self.assertEqual(after, 'defscrollback 25000\nmultiuser off\nacladd customuser\nbind x quit\n')
        self.assertEqual(migration.migrate_text(after, screen=True), after)

    def test_only_managed_mutation_aliases_change(self):
        before = "alias mcstart='/opt/minecraft/start-server.sh'\nalias mcstop='sudo /opt/minecraft/stop-server.sh'\nalias mcrestart='/opt/minecraft/server-manager.sh restart'\nalias mcstatus='/opt/minecraft/server-manager.sh status'\nalias mcstart_custom='custom-command'\n"
        after = migration.migrate_text(before)
        self.assertIn("alias mcstart='sudo /opt/minecraft/start-server.sh'", after)
        self.assertIn("alias mcrestart='sudo /opt/minecraft/server-manager.sh restart'", after)
        self.assertIn("alias mcstatus='/opt/minecraft/server-manager.sh status'", after)
        self.assertIn("alias mcstart_custom='custom-command'", after)
        self.assertEqual(migration.migrate_text(after), after)

    def test_file_backup_metadata_and_repeat_runs(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / '.screenrc'
            original = 'multiuser on\nacladd root\ncustom setting\n'
            path.write_text(original)
            path.chmod(0o640)
            self.assertTrue(migration.migrate_file(path, screen=True))
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
            backup = Path(str(path) + '.pre-hardening')
            self.assertEqual(backup.read_text(), original)
            self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
            unchanged = path.stat().st_mtime_ns
            self.assertFalse(migration.migrate_file(path, screen=True))
            self.assertEqual(path.stat().st_mtime_ns, unchanged)
            self.assertEqual(backup.read_text(), original)

    def test_symlink_settings_and_backups_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / '.screenrc'
            target = Path(tmp) / 'target'
            target.write_text('multiuser on\n')
            path.symlink_to(target)
            with self.assertRaises(ValueError):
                migration.migrate_file(path, screen=True)
            path.unlink()
            path.write_text('multiuser on\n')
            Path(str(path) + '.pre-hardening').symlink_to(target)
            with self.assertRaises(ValueError):
                migration.migrate_file(path, screen=True)
            self.assertEqual(target.read_text(), 'multiuser on\n')
            self.assertEqual(path.read_text(), 'multiuser on\n')

    def test_missing_settings_files_are_optional(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(migration.migrate_file(Path(tmp) / 'missing'))


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.server = self.base / 'server'
        self.server.mkdir()
        (self.server / 'worlds').mkdir()
        self.world = self.server / 'worlds' / 'level.dat'
        self.world.write_bytes(b'existing world')
        self.binary = self.server / 'bedrock_server'
        self.binary.write_bytes(b'existing binary')
        self.home = self.base / 'home'
        self.home.mkdir()
        self.screenrc = self.home / '.screenrc'
        self.screenrc.write_text('multiuser on\nacladd root\ndefscrollback 77777\n')
        self.aliases = self.home / '.bash_aliases'
        self.aliases.write_text("alias mcstart='/opt/minecraft/start-server.sh'\nalias custom='keep me'\n")
        self.system_aliases = self.base / 'system-aliases'
        self.system_aliases.write_text("alias mcstop='/opt/minecraft/stop-server.sh'\n")
        self.config = self.base / 'config.sh'
        # Old installations have TEMP_DIR and no MAX_EXTRACTED_BYTES.
        config_text = (ROOT / 'config.sh').read_text()
        config_text = '\n'.join(line for line in config_text.splitlines() if not line.startswith('MAX_EXTRACTED_BYTES='))
        self.config.write_text(config_text + '\nTEMP_DIR="/tmp/minecraft-update"\n# local customization\n')
        self.config_before = self.config.read_bytes()
        self.backups = self.base / 'backups'
        self.backups.mkdir()
        self.backup = self.backups / 'minecraft-backup-existing.tar.gz'
        self.backup.write_bytes(b'existing backup')
        self.backup.chmod(0o644)
        self.events = self.base / 'events'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        fake_chown = self.bin / 'chown'
        fake_chown.write_text('#!/bin/bash\nexit 0\n')
        fake_chown.chmod(0o755)
        text = (ROOT / 'setup.sh').read_text().removesuffix('main "$@"\n')
        text = text.replace('SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"', f'SCRIPT_DIR={q(str(ROOT))}')
        text = text.replace('source "$SCRIPT_DIR/config.sh"', f'source {q(str(self.config))}')
        text = text.replace('/etc/profile.d/minecraft.sh', str(self.system_aliases))
        self.library = self.base / 'setup-library.sh'
        self.library.write_text(text)
        self.prefix = f'''
source {q(str(self.library))}
PATH={q(str(self.bin))}:"$PATH"
SERVER_DIR={q(str(self.server))}
BACKUP_DIR={q(str(self.backups))}
LOG_DIR={q(str(self.base / 'logs'))}
EVENTS={q(str(self.events))}
get_server_home() {{ SERVER_HOME={q(str(self.home))}; }}
check_root() {{ :; }}
check_requirements() {{ :; }}
validate_config() {{ :; }}
acquire_management_lock() {{ echo lock >> "$EVENTS"; }}
has_server_process() {{ return 1; }}
has_screen_session() {{ return 1; }}
repair_screen_runtime() {{ echo repair-screen >> "$EVENTS"; }}
chown() {{ :; }}
setup_script_permissions() {{ echo scripts >> "$EVENTS"; }}
create_user() {{ echo unexpected >> "$EVENTS"; return 20; }}
create_aliases() {{ echo unexpected >> "$EVENTS"; return 20; }}
setup_update_cron() {{ echo unexpected >> "$EVENTS"; return 20; }}
create_systemd_service() {{ echo unexpected >> "$EVENTS"; return 20; }}
setup_firewall() {{ echo unexpected >> "$EVENTS"; return 20; }}
'''

    def run_setup(self, args='--upgrade', overrides=''):
        return subprocess.run(['bash', '-c', self.prefix + overrides + '\nmain ' + args], capture_output=True, text=True)

    def assert_data_preserved(self):
        self.assertEqual(self.world.read_bytes(), b'existing world')
        self.assertEqual(self.binary.read_bytes(), b'existing binary')
        self.assertEqual(self.backup.read_bytes(), b'existing backup')
        self.assertEqual(self.config.read_bytes(), self.config_before)

    def test_upgrade_is_repeatable_and_preserves_data_and_custom_settings(self):
        for _ in range(2):
            result = self.run_setup()
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assert_data_preserved()
        self.assertIn('multiuser off', self.screenrc.read_text())
        self.assertIn('defscrollback 77777', self.screenrc.read_text())
        self.assertIn("alias custom='keep me'", self.aliases.read_text())
        self.assertIn('sudo /opt/minecraft/start-server.sh', self.aliases.read_text())
        self.assertIn('sudo /opt/minecraft/stop-server.sh', self.system_aliases.read_text())
        self.assertEqual(stat.S_IMODE(self.backups.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.backup.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.server.stat().st_mode), 0o750)
        self.assertNotIn('unexpected', self.events.read_text())
        self.assertIn('multiuser on', Path(str(self.screenrc) + '.pre-hardening').read_text())

    def test_upgrade_refuses_a_running_server_before_changes(self):
        result = self.run_setup(overrides='has_server_process() { return 0; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Stop the existing server', result.stdout)
        self.assert_data_preserved()
        self.assertIn('multiuser on', self.screenrc.read_text())
        self.assertNotIn('repair-screen', self.events.read_text())

    def test_check_is_read_only(self):
        result = self.run_setup('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_data_preserved()
        self.assertFalse(self.events.exists())
        self.assertEqual(stat.S_IMODE(self.backup.stat().st_mode), 0o644)
        self.assertIn('multiuser on', self.screenrc.read_text())

    def test_installation_precedes_dependency_and_configuration_checks(self):
        overrides = '''
install_dependencies() { echo install >> "$EVENTS"; INSTALLED=true; }
check_requirements() { [[ "${INSTALLED:-false}" == true ]]; }
validate_config() { [[ "${INSTALLED:-false}" == true ]]; }
'''
        result = self.run_setup('--upgrade --install-dependencies', overrides)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events.read_text().splitlines()[0], 'install')

    def test_check_cannot_install_packages(self):
        result = self.run_setup('--check --install-dependencies', 'install_dependencies() { echo install >> "$EVENTS"; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.events.exists())

    def test_invalid_options_do_not_mutate_installation(self):
        for options in ('--unknown', '--check --upgrade'):
            result = self.run_setup(options)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.events.exists())
            self.assert_data_preserved()

    def test_missing_dependencies_are_reported_with_upgrade_command(self):
        # Load the real check_requirements again rather than the fixture override.
        script = self.prefix + f'\nsource {q(str(self.library))}\n'
        script += 'command() { if [[ "$1" == -v && "$2" == python3 ]]; then return 1; fi; builtin command "$@"; }\ncheck_requirements'
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Required command not found: python3', result.stdout)
        self.assertIn('--upgrade --install-dependencies', result.stdout)
        self.assertFalse(self.events.exists())

    def screen_script(self, restore=True):
        shared = self.base / 'screen'
        shared.mkdir()
        shared.chmod(0o777)
        user = shared / 'S-mcserver'
        user.mkdir()
        user.chmod(0o755)
        other = shared / 'S-other'
        other.mkdir()
        other.chmod(0o750)
        library = self.base / 'screen-library.sh'
        text = self.library.read_text().replace('/var/run/screen', str(self.base / 'unused')).replace('/run/screen', str(shared))
        library.write_text(text)
        script = f'source {q(str(library))}\nchown() {{ :; }}\nid() {{ echo mcserver; }}\n'
        script += "stat() { python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' \"$3\"; }\n"
        script += f'systemd-tmpfiles() {{ printf "%s\\n" "$*" >> {q(str(self.events))}; '
        script += f'chmod 775 {q(str(shared))}; }}\n' if restore else ':; }\n'
        script += 'repair_screen_runtime\n'
        return script, shared, user, other

    def test_screen_repair_uses_distribution_defaults_and_preserves_other_users(self):
        script, shared, user, other = self.screen_script()
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--create --prefix=', self.events.read_text())
        self.assertNotIn('--remove', self.events.read_text())
        self.assertEqual(stat.S_IMODE(shared.stat().st_mode), 0o775)
        self.assertEqual(stat.S_IMODE(user.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(other.stat().st_mode), 0o750)

    def test_screen_repair_reports_package_reinstallation_if_defaults_not_restored(self):
        script, shared, user, other = self.screen_script(restore=False)
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('sudo apt-get install --reinstall screen', result.stdout)
        self.assertEqual(stat.S_IMODE(shared.stat().st_mode), 0o777)
        self.assertEqual(stat.S_IMODE(user.stat().st_mode), 0o755)

    def test_package_installation_dispatch_does_not_run_without_flag(self):
        result = self.run_setup(overrides='install_dependencies() { echo unexpected-install >> "$EVENTS"; return 30; }')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('unexpected-install', self.events.read_text())


if __name__ == '__main__':
    unittest.main()
