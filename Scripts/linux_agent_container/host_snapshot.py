#!/usr/bin/env python3
"""Copy one host credential file into a private snapshot for a Docker mount.

Runs on the host (it is not installed in the image):

  host_snapshot.py SOURCE DEST

Docker resolves symlinks in a bind-mount source when the container starts, so
checking a path and then mounting it could mount a different file. Instead the
wrapper mounts DEST, a copy made here: SOURCE is opened by walking every path
component from / with O_NOFOLLOW (a symlink anywhere in the path, including a
parent swapped for one, is refused) and must be a regular file of at most 1 MiB.
DEST is created exclusively with mode 0600 inside the wrapper's private 0700
directory. File contents are never printed.
"""

import os
import stat
import sys

MAX_BYTES = 1 << 20
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class Refused(Exception):
    pass


def components(path):
    if not path.startswith("/") or any(ord(char) < 0x20 or ord(char) == 0x7F for char in path):
        raise Refused("the path must be absolute and free of control characters")
    parts = path[1:].split("/")
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise Refused("the path must be normalized (no empty, '.' or '..' components)")
    return parts


def read_source(path):
    parts = components(path)
    fd = os.open("/", DIR_FLAGS)
    try:
        for part in parts[:-1]:
            try:
                child = os.open(part, DIR_FLAGS, dir_fd=fd)
            except OSError:
                raise Refused(f"parent {part} is missing or not a real directory") from None
            os.close(fd)
            fd = child
        try:
            # O_NONBLOCK: never hang on a FIFO swapped in for the file.
            source = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd)
        except OSError as error:
            raise Refused(f"cannot open the file without following symlinks ({error.strerror})") from None
    finally:
        os.close(fd)
    with os.fdopen(source, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise Refused("not a regular file")
        data = handle.read(MAX_BYTES + 1)
    if not data or len(data) > MAX_BYTES:
        raise Refused(f"empty or larger than {MAX_BYTES} bytes")
    return data


def write_snapshot(dest, data):
    directory, name = os.path.split(dest)
    dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        info = os.fstat(dir_fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise Refused("the snapshot directory is not private to this user")
        out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dir_fd)
        try:
            view = memoryview(data)
            while view:
                view = view[os.write(out, view):]
            os.fsync(out)
        finally:
            os.close(out)
    finally:
        os.close(dir_fd)


def main(argv):
    if len(argv) != 2:
        print("usage: host_snapshot.py SOURCE DEST", file=sys.stderr)
        return 2
    source, dest = argv
    os.umask(0o077)
    try:
        write_snapshot(dest, read_source(source))
    except Refused as error:
        print(f"refused {source}: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"could not snapshot {source} ({error.strerror or error})", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
