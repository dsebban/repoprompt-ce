#!/usr/bin/env python3
"""Copy explicitly staged credential files into this container's home volume.

The host wrapper bind-mounts only the files the user named, read-only, at
/run/rpce-import/<tool>/<name>. An existing destination is never replaced:
anything already at a destination path (file, directory, or symlink, including
a dangling one) refuses the whole import before anything is written, and the
final step is an atomic no-replace hard link, so a destination created
concurrently also refuses the import. Parent directories must be real
directories (not symlinks). File contents are never printed.

Exit status (callers such as the host-auth wrapper depend on these):
  0  every staged file was imported
  1  write failure (for example ENOSPC or EIO) while creating a directory or
     writing, syncing or linking a file; this run's temporary file is removed
     and nothing that existed was replaced. Retrying can succeed.
  2  usage error (arguments were given)
  3  refused: a destination already exists in this volume, or appeared during
     the import; it was left unchanged. Retrying gives the same result.
  4  refused: invalid or unsafe input (a staged file that is missing, not a
     regular file, too large or not valid JSON/TOML; a relocated CODEX_HOME or
     XDG_DATA_HOME; HOME not absolute; a destination parent that is a symlink
     or not a directory).
With several staged files, files imported before a failure stay imported and
the status describes the failure.
"""

import contextlib
import json
import os
import secrets
import stat
import sys
import tomllib

IMPORT_ROOT = "/run/rpce-import"
MAX_BYTES = 1 << 20

EXIT_IMPORTED = 0
EXIT_WRITE_FAILED = 1
EXIT_USAGE = 2
EXIT_EXISTS = 3
EXIT_INVALID = 4

# tool: (staged file name, destination path components under $HOME, format)
TOOLS = {
    "claude": (".credentials.json", (".claude", ".credentials.json"), "json"),
    "codex": ("auth.json", (".codex", "auth.json"), "json"),
    "devin": ("credentials.toml", (".local", "share", "devin", "credentials.toml"), "toml"),
}


class Refused(Exception):
    """Invalid or unsafe input, or (with a status) another non-success outcome."""

    status = EXIT_INVALID


class Exists(Refused):
    status = EXIT_EXISTS


class WriteFailed(Refused):
    status = EXIT_WRITE_FAILED


def display(parts):
    return "~/" + "/".join(parts)


def check_environment(home):
    # Destinations must be where the tools look for them in this container.
    expected = {"CODEX_HOME": os.path.join(home, ".codex"), "XDG_DATA_HOME": os.path.join(home, ".local", "share")}
    for name, path in expected.items():
        value = os.environ.get(name)
        if value is not None and os.path.normpath(value) != path:
            raise Refused(f"{name}={value} differs from {path}; credential destinations would not match")


def read_staged(tool):
    staged, parts, kind = TOOLS[tool]
    path = os.path.join(IMPORT_ROOT, tool, staged)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise Refused(f"{tool}: cannot open staged file ({error.strerror})") from None
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise Refused(f"{tool}: staged file is not a regular file")
        if info.st_size > MAX_BYTES:
            raise Refused(f"{tool}: staged file is larger than {MAX_BYTES} bytes")
        data = handle.read(MAX_BYTES + 1)
    if not data or len(data) > MAX_BYTES:
        raise Refused(f"{tool}: staged file is empty or too large")
    try:
        text = data.decode("utf-8")
        valid = isinstance(json.loads(text), dict) if kind == "json" else isinstance(tomllib.loads(text), dict)
    except (UnicodeDecodeError, ValueError):
        valid = False
    if not valid:
        # Parser messages can quote input; report only the expected format.
        raise Refused(f"{tool}: staged file is not a valid {kind.upper()} document")
    return (tool, parts, data)


def open_parent(home, parts, create):
    """Return a directory fd for the destination's parent, refusing symlinks."""
    try:
        fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        raise Refused(f"HOME {home} is not a real directory") from None
    try:
        for component in parts[:-1]:
            if create:
                try:
                    os.mkdir(component, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                except OSError as error:
                    raise WriteFailed(f"could not create {display(parts)}: parent {component} "
                                      f"({error.strerror or error})") from None
            try:
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            except FileNotFoundError:
                if create:
                    raise WriteFailed(f"{display(parts)}: parent {component} changed during import") from None
                return None
            except OSError:
                raise Refused(f"{display(parts)}: parent {component} is not a real directory") from None
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def preflight(home, items):
    for tool, parts, _ in items:
        fd = open_parent(home, parts, create=False)
        if fd is None:
            continue
        try:
            os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        finally:
            os.close(fd)
        raise Exists(f"{tool}: {display(parts)} already exists in this state volume")


def remove_own_temporary(dir_fd, name, identity):
    """Unlink `name` only if it is still the file this run created."""
    try:
        current = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if (current.st_dev, current.st_ino) == identity:
        os.unlink(name, dir_fd=dir_fd)


def install(home, item):
    tool, parts, data = item
    fd = open_parent(home, parts, create=True)
    try:
        temporary = f".{parts[-1]}.rpce-import-{secrets.token_hex(8)}"
        try:
            out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600,
                          dir_fd=fd)
        except OSError as error:
            raise WriteFailed(f"{tool}: could not write {display(parts)} ({error.strerror or error})") from None
        # From here on the temporary name exists; every exit path, including a
        # failed write, fsync or link, removes it (and only it, by inode).
        identity = None
        try:
            created = os.fstat(out)
            identity = (created.st_dev, created.st_ino)
            try:
                os.fchmod(out, 0o600)
                view = memoryview(data)
                while view:
                    view = view[os.write(out, view):]
                os.fsync(out)
            finally:
                os.close(out)
            try:
                # link(2) never replaces an existing name, including a dangling symlink.
                os.link(temporary, parts[-1], src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
            except FileExistsError:
                raise Exists(f"{tool}: {display(parts)} appeared during import; it was left unchanged") from None
        except OSError as error:
            raise WriteFailed(f"{tool}: could not write {display(parts)} ({error.strerror or error})") from None
        finally:
            if identity is not None:
                remove_own_temporary(fd, temporary, identity)
            else:
                # fstat failed right after an O_EXCL create: the name is ours.
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(temporary, dir_fd=fd)
        try:
            os.fsync(fd)
        except OSError as error:
            raise WriteFailed(f"{tool}: could not sync the directory of {display(parts)} "
                              f"({error.strerror or error})") from None
    finally:
        os.close(fd)
    print(f"imported {tool}: {display(parts)}")


def main(argv):
    if argv:
        print("rpce-import-credentials takes no arguments; existing credentials are never replaced.", file=sys.stderr)
        return EXIT_USAGE
    home = os.environ.get("HOME", "")
    if not os.path.isabs(home):
        print("refused: HOME is not an absolute path", file=sys.stderr)
        return EXIT_INVALID
    os.umask(0o077)
    try:
        check_environment(home)
        items = [item for item in (read_staged(tool) for tool in TOOLS) if item is not None]
        if not items:
            print("refused: no staged credential files were found", file=sys.stderr)
            return EXIT_INVALID
        preflight(home, items)
    except Refused as error:
        print(f"refused {error}; nothing was imported.", file=sys.stderr)
        if error.status == EXIT_EXISTS:
            print("Existing credentials are never replaced. To import into a separate volume, use a new --state NAME.",
                  file=sys.stderr)
        return error.status
    for index, item in enumerate(items):
        try:
            install(home, item)
        except Refused as error:
            # A concurrent writer, an unsafe parent or a write failure. Files
            # imported before it stay; nothing that existed was replaced or removed.
            done = [tool for tool, _, _ in items[:index]]
            remaining = [tool for tool, _, _ in items[index + 1:]]
            verb = "failed:" if error.status == EXIT_WRITE_FAILED else "refused"
            print(f"{verb} {error}.", file=sys.stderr)
            print(f"Already imported: {', '.join(done) or 'none'}. Not attempted: {', '.join(remaining) or 'none'}.", file=sys.stderr)
            if error.status == EXIT_WRITE_FAILED:
                print("If the disk is full, free space (for Docker, check `docker system df`) and import again.",
                      file=sys.stderr)
            return error.status
    return EXIT_IMPORTED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
