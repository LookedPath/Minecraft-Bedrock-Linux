#!/usr/bin/env python3
"""Validate a Bedrock zip completely before extracting it into a private directory."""
import os
from pathlib import PurePosixPath
import stat
import sys
import zipfile


def extract(archive, destination, executable, max_bytes):
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        if len(entries) > 100000 or sum(i.file_size for i in entries) > max_bytes:
            raise ValueError("Archive exceeds extraction limits")
        seen = set()
        for entry in entries:
            path = PurePosixPath(entry.filename)
            mode = entry.external_attr >> 16
            if (not entry.filename or path.is_absolute() or ".." in path.parts
                    or "\\" in entry.filename or "\x00" in entry.filename
                    or any(ord(c) < 32 for c in entry.filename)
                    or path.as_posix() in (".", "")
                    or path.as_posix() in seen
                    or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))):
                raise ValueError(f"Unsafe archive entry: {entry.filename!r}")
            seen.add(path.as_posix())
        binary = next((i for i in entries if i.filename == executable), None)
        if binary is None or binary.is_dir():
            raise ValueError("Archive has no server executable")
        # Official Linux Bedrock builds are x86-64 ELF binaries.
        with zipped.open(binary) as stream:
            header = stream.read(20)
        if len(header) < 20 or header[:6] != b"\x7fELF\x02\x01" or header[18:20] != b"\x3e\x00":
            raise ValueError("Server executable is not an x86-64 Linux ELF binary")
        if zipped.testzip() is not None:
            raise ValueError("Archive CRC validation failed")
        zipped.extractall(destination)


if __name__ == "__main__":
    try:
        extract(sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]))
    except (ValueError, OSError, zipfile.BadZipFile, RuntimeError) as error:
        sys.exit(f"Invalid server archive: {error}")
