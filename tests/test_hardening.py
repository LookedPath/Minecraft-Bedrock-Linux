"""Isolated regressions: no root privileges, live server, network, or Screen required."""
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import warnings
import stat
import subprocess
import tarfile
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
q = shlex.quote
spec = importlib.util.spec_from_file_location('archive', ROOT / 'validate-archive.py')
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)
ELF = b'\x7fELF\x02\x01' + b'\0' * 12 + b'\x3e\x00' + b'fixture'


class ArchiveTests(unittest.TestCase):
    def run_archive(self, entries, limit=1024):
        with tempfile.TemporaryDirectory() as tmp:
            zipped = Path(tmp) / 'server.zip'
            with zipfile.ZipFile(zipped, 'w') as z:
                z.writestr('bedrock_server', ELF)
                for name, data in entries:
                    with warnings.catch_warnings():
                        warnings.simplefilter('ignore', UserWarning)
                        z.writestr(name, data)
            archive.extract(zipped, Path(tmp) / 'output', 'bedrock_server', limit)
            self.assertTrue((Path(tmp) / 'output' / 'bedrock_server').is_file())

    def test_valid_archive(self):
        self.run_archive([('resource_packs/default/file', b'data')])

    def test_traversal_absolute_and_backslash(self):
        for name in ('../outside', '/outside', 'a/../../outside', 'a\\outside'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.run_archive([(name, b'data')])

    def test_symlink(self):
        info = zipfile.ZipInfo('link')
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with self.assertRaises(ValueError):
            self.run_archive([(info, b'/etc/passwd')])

    def test_size_limit(self):
        with self.assertRaises(ValueError):
            self.run_archive([('large', b'x' * 2048)])

    def test_duplicate_entries(self):
        with self.assertRaises(ValueError):
            self.run_archive([('bedrock_server', ELF)])

    def test_invalid_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            zipped = Path(tmp) / 'server.zip'
            with zipfile.ZipFile(zipped, 'w') as z:
                z.writestr('bedrock_server', b'not an ELF')
            with self.assertRaises(ValueError):
                archive.extract(zipped, Path(tmp) / 'output', 'bedrock_server', 1024)


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.server = self.base / 'server'
        self.server.mkdir()
        (self.server / 'bedrock_server').write_text('old binary')
        (self.server / '.installed_version').write_text('VERSION=1.0.0.0\n')
        (self.server / 'worlds').mkdir()
        (self.server / 'worlds' / '.hidden-world').write_text('world data')
        self.events = self.base / 'events'
        self.runtime = self.base / 'running'
        self.runtime.touch()
        # Load the actual function bodies, omitting only automatic main execution.
        text = (ROOT / 'update-server.sh').read_text().removesuffix('main "$@"\n')
        text = text.replace('SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"', f'SCRIPT_DIR={q(str(ROOT))}')
        self.library = self.base / 'updater.sh'
        self.library.write_text(text)
        self.prefix = f'''
source {q(str(self.library))}
SERVER_DIR={q(str(self.server))}
BACKUP_DIR={q(str(self.base / 'backups'))}
LOG_DIR={q(str(self.base / 'logs'))}
LOG_FILE="$LOG_DIR/manage.log"
EVENTS={q(str(self.events))}
RUNNING={q(str(self.runtime))}
log() {{ :; }}
check_root() {{ :; }}
check_requirements() {{ :; }}
validate_config() {{ :; }}
chown() {{ :; }}
setup_directories() {{
    mkdir -p "$BACKUP_DIR"
    WORK_DIR=$(mktemp -d {q(str(self.base))}/work.XXXXXXXX)
    TEMP_DIR="$WORK_DIR"
}}
get_latest_download_url() {{ DETECTED_DOWNLOAD_URL="https://example.test/bedrock-server-1.0.0.1.zip"; }}
is_server_running() {{ [[ -f "$RUNNING" ]]; }}
stop_server() {{ echo stop >> "$EVENTS"; rm "$RUNNING"; }}
download_server() {{ echo download >> "$EVENTS"; DOWNLOADED_FILE="$WORK_DIR/download"; }}
extract_server() {{
    echo validate >> "$EVENTS"
    EXTRACTED_DIR="$WORK_DIR/extracted"
    mkdir -p "$EXTRACTED_DIR/worlds"
    echo 'new binary' > "$EXTRACTED_DIR/bedrock_server"
    echo default > "$EXTRACTED_DIR/worlds/default"
}}
start_server() {{ echo start >> "$EVENTS"; touch "$RUNNING"; }}
notify_update_start() {{ :; }}
notify_no_update() {{ :; }}
notify_update_success() {{ echo success >> "$EVENTS"; }}
notify_update_failure() {{ echo failure >> "$EVENTS"; }}
cleanup_old_backups() {{ :; }}
'''

    def run_update(self, overrides=''):
        return subprocess.run(['bash', '-c', self.prefix + overrides + '\nmain'], capture_output=True, text=True)

    def event_list(self):
        return self.events.read_text().splitlines()

    def assert_old(self):
        self.assertEqual((self.server / 'bedrock_server').read_text(), 'old binary')
        self.assertEqual((self.server / 'worlds' / '.hidden-world').read_text(), 'world data')

    def test_success_preserves_hidden_world_and_complete_backup(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.event_list(), ['download', 'validate', 'stop', 'start', 'success'])
        self.assertEqual((self.server / 'worlds' / '.hidden-world').read_text(), 'world data')
        self.assertFalse((self.server / 'worlds' / 'default').exists())
        self.assertIn('VERSION=1.0.0.1', (self.server / '.installed_version').read_text())
        backups = list((self.base / 'backups').glob('*.tar.gz'))
        self.assertEqual(len(backups), 1)
        with tarfile.open(backups[0]) as tar:
            self.assertIn('server/.installed_version', tar.getnames())
            self.assertIn('server/worlds/.hidden-world', tar.getnames())
        self.assertFalse(list(self.base.glob('.minecraft-install.*')))
        self.assertFalse(list(self.base.glob('work.*')))

    def test_download_failure_does_not_stop_server(self):
        result = self.run_update('download_server() { echo download >> "$EVENTS"; return 7; }')
        self.assertEqual(result.returncode, 7)
        self.assert_old()
        self.assertTrue(self.runtime.exists())
        self.assertEqual(self.event_list(), ['download', 'failure'])

    def test_validation_failure_does_not_stop_server(self):
        result = self.run_update('extract_server() { return 8; }')
        self.assertEqual(result.returncode, 8)
        self.assert_old()
        self.assertTrue(self.runtime.exists())
        self.assertNotIn('stop', self.event_list())

    def test_copy_failure_keeps_old_installation_and_restarts(self):
        result = self.run_update('cp() { if [[ "$3" == "$EXTRACTED_DIR/." ]]; then return 9; fi; command cp "$@"; }')
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assert_old()
        self.assertTrue(self.runtime.exists())
        self.assertNotIn('success', self.event_list())

    def test_start_failure_rolls_back_and_restarts_old_binary(self):
        result = self.run_update('start_server() { if grep -q "new binary" "$SERVER_DIR/bedrock_server"; then return 10; fi; echo recovered >> "$EVENTS"; touch "$RUNNING"; }')
        self.assertEqual(result.returncode, 10, result.stderr)
        self.assert_old()
        self.assertTrue(self.runtime.exists())
        self.assertIn('recovered', self.event_list())
        self.assertNotIn('success', self.event_list())

    def test_promotion_failure_restores_previous_directory(self):
        result = self.run_update('mv() { if [[ "$2" == */new ]]; then return 11; fi; command mv "$@"; }')
        self.assertEqual(result.returncode, 11, result.stderr)
        self.assert_old()
        self.assertTrue(self.runtime.exists())

    def test_termination_after_promotion_rolls_back(self):
        result = self.run_update('start_server() { if grep -q "new binary" "$SERVER_DIR/bedrock_server"; then kill -TERM $$; fi; touch "$RUNNING"; }')
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assert_old()
        self.assertTrue(self.runtime.exists())
        self.assertFalse(list(self.base.glob('work.*')))

    def test_stopped_server_stays_stopped(self):
        self.runtime.unlink()
        result = self.run_update('stop_server() { :; }')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.runtime.exists())
        self.assertNotIn('start', self.event_list())

    def test_symlink_in_preserved_world_is_rejected(self):
        (self.server / 'worlds' / 'link').symlink_to(self.base / 'outside')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertTrue(self.runtime.exists())

    def test_stop_failure_aborts_installation(self):
        result = self.run_update('stop_server() { return 12; }')
        self.assertEqual(result.returncode, 12)
        self.assert_old()
        self.assertTrue(self.runtime.exists())


class SharedChecksTests(unittest.TestCase):
    def run_common(self, script):
        return subprocess.run(['bash', '-c', f'source {q(str(ROOT / "config.sh"))}\nsource {q(str(ROOT / "common.sh"))}\n' + script], capture_output=True, text=True)

    def test_exact_screen_session(self):
        for session, expected in [('minecraft-server-extra', 1), ('minecraft-server', 0)]:
            script = f'sudo() {{ printf "  123.{session} (Detached)\\n"; }}\nhas_screen_session'
            self.assertEqual(self.run_common(script).returncode, expected)

    def test_invalid_paths_and_preservation_entries(self):
        # Portable realpath shim: configuration checks use GNU realpath -m on Linux.
        prefix = "realpath() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \"${@: -1}\"; }\n"
        prefix += 'SERVER_DIR=/srv/bedrock; BACKUP_DIR=/srv/backups; LOG_DIR=/srv/logs; LOG_FILE="$LOG_DIR/manage.log"\n'
        self.assertEqual(self.run_common(prefix + 'validate_config').returncode, 0)
        for changes in ('SERVER_DIR=/', 'SERVER_DIR=/home/mcserver', 'SERVER_DIR=/proc/data',
                        'BACKUP_DIR="$SERVER_DIR/backups"', 'SERVER_DIR=/srv/../srv/bedrock',
                        'PRESERVE_FILES=(../outside)', 'PRESERVE_FILES=(bedrock_server)', 'LOG_FILE="$LOG_DIR/../outside"',
                        'SERVER_EXECUTABLE=../binary', 'BACKUP_RETENTION_DAYS=-1'):
            with self.subTest(changes=changes):
                self.assertNotEqual(self.run_common(prefix + changes + '\nvalidate_config').returncode, 0)

    @unittest.skipUnless(Path('/proc/self/exe').exists(), 'Linux /proc required')
    def test_only_configured_executable_and_directory_are_signaled(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            server, other = base / 'server', base / 'other'
            server.mkdir(); other.mkdir()
            for path in (server, other):
                shutil.copy2('/bin/sleep', path / 'bedrock_server')
            target = subprocess.Popen([str(server / 'bedrock_server'), '30'], cwd=server)
            unrelated = subprocess.Popen([str(other / 'bedrock_server'), '30'], cwd=other)
            try:
                result = self.run_common(f'SERVER_USER=$(id -un); SERVER_DIR={q(str(server))}\nserver_pids\nsignal_server TERM')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), str(target.pid))
                target.wait(timeout=5)
                self.assertIsNone(unrelated.poll())
            finally:
                for process in (target, unrelated):
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)

    def test_management_lock_excludes_concurrent_operations(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            library = base / 'common.sh'
            library.write_text((ROOT / 'common.sh').read_text().replace('local lock_dir=/run/lock/minecraft-bedrock', f'local lock_dir={q(str(base / "lock"))}'))
            # fcntl uses the same flock semantics on Linux and macOS, retaining fd 9's lock.
            prefix = f'source {q(str(library))}\n'
            prefix += "stat() { case \"$2\" in %u) echo 0;; %a) echo 700;; esac; }\n"
            prefix += "flock() { python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; }\n"
            ready = base / 'ready'
            first = subprocess.Popen(['bash', '-c', prefix + f'acquire_management_lock || exit 1; touch {q(str(ready))}; sleep 3'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 3
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists())
                second = subprocess.run(['bash', '-c', prefix + 'acquire_management_lock'], capture_output=True, text=True)
                self.assertNotEqual(second.returncode, 0)
            finally:
                first.communicate(timeout=5)
            third = subprocess.run(['bash', '-c', prefix + 'acquire_management_lock'], capture_output=True, text=True)
            self.assertEqual(third.returncode, 0, third.stderr)


class LifecycleTests(unittest.TestCase):
    def run_functions(self, name, script):
        with tempfile.TemporaryDirectory() as tmp:
            text = (ROOT / name).read_text().removesuffix('main "$@"\n')
            text = text.replace('SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"', f'SCRIPT_DIR={q(str(ROOT))}')
            text = text.replace('validate_config || { printf "%s\\n" "Unsafe or invalid configuration" >&2; exit 1; }', ':')
            library = Path(tmp) / name
            library.write_text(text)
            return subprocess.run(['bash', '-c', f'source {q(str(library))}\nlog() {{ :; }}\n' + script], capture_output=True, text=True)

    def test_graceful_stop_waits_past_first_increment(self):
        result = self.run_functions('stop-server.sh', '''
C=0
sleep() { C=$((C + 1)); }
is_server_running() { [[ "$C" -lt 8 ]]; }
send_server_command() { :; }
has_screen_session() { return 1; }
graceful_stop force
[[ "$C" == 8 && "$SAVE_HELD" == false ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_force_stop_escalates_when_term_does_not_exit(self):
        result = self.run_functions('stop-server.sh', '''
C=0; KILLED=false
sleep() { C=$((C + 1)); }
has_server_process() { [[ "$KILLED" == false ]]; }
has_screen_session() { return 1; }
is_server_running() { has_server_process; }
signal_server() { echo "$1"; if [[ "$1" == KILL ]]; then KILLED=true; fi; }
force_stop
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['TERM', 'KILL'])

    def test_save_hold_is_released_on_termination(self):
        result = self.run_functions('stop-server.sh', '''
sudo() { printf '%s\\n' "$*"; }
SAVE_HELD=true
kill -TERM $$
''')
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertIn('save resume', result.stdout)

    def test_start_failure_propagates(self):
        result = self.run_functions('start-server.sh', '''
SERVER_DIR=/tmp
C=0
sudo() { :; }
sleep() { C=$((C + 1)); }
has_screen_session() { :; }
has_server_process() { [[ "$C" -lt 5 ]]; }
start_server
''')
        self.assertEqual(result.returncode, 1, result.stderr)


if __name__ == '__main__':
    unittest.main()
