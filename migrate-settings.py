#!/usr/bin/env python3
"""Migrate only legacy managed Screen directives and mutation aliases."""
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


def migrate_text(text, screen=False):
    if screen:
        text = re.sub(r'(?m)^([ \t]*)multiuser[ \t]+on[ \t]*(?:#.*)?$', r'\1multiuser off', text)
        text = re.sub(r'(?m)^[ \t]*acladd[ \t]+root[ \t]*(?:#.*)?\n?', '', text)
        return text
    pattern = re.compile(r"(?m)^(alias (?:mcstart|mcstop|mcrestart)=)(['\"])([^\n]*)(\2)$")

    def add_sudo(match):
        command = match[3]
        if command.endswith(('/start-server.sh', '/stop-server.sh', '/server-manager.sh restart')) and not command.startswith('sudo '):
            return f'{match[1]}{match[2]}sudo {command}{match[4]}'
        return match[0]

    return pattern.sub(add_sudo, text)


def migrate_file(path, screen=False):
    path = Path(path)
    if not path.exists() and not path.is_symlink():
        return False
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f'Refusing non-regular settings file: {path}')
    original = path.read_bytes()
    updated = migrate_text(original.decode('utf-8'), screen).encode('utf-8')
    if updated == original:
        return False
    backup = Path(str(path) + '.pre-hardening')
    try:
        # Never truncate an earlier backup or follow a pre-existing backup symlink.
        with backup.open('xb') as stream:
            stream.write(original)
        os.chmod(backup, 0o600)
    except FileExistsError:
        if not stat.S_ISREG(backup.lstat().st_mode):
            raise ValueError(f'Refusing non-regular backup: {backup}')
    fd, temporary = tempfile.mkstemp(prefix='.minecraft-migrate-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(info.st_mode))
        os.chown(temporary, info.st_uid, info.st_gid)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


if __name__ == '__main__':
    try:
        for index, filename in enumerate(sys.argv[1:]):
            if migrate_file(filename, screen=index == 0):
                print(f'Migrated {filename}; original saved as {filename}.pre-hardening')
    except (OSError, UnicodeError, ValueError) as error:
        sys.exit(str(error))
