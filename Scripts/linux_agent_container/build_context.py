#!/usr/bin/env python3
"""Write the container build context as a tar stream on stdout.

The context contains only (1) files git tracks under the build input paths,
read from the working tree so uncommitted edits to tracked files are included,
and (2) the container's own scripts in this directory. Untracked and ignored
files are never included, whatever their name. No path component is
followed through a symlink: tracked symlinks are archived as symlinks, and a
symlinked or swapped parent directory refuses the whole context. Docker reads
the stream with `docker build -f Dockerfile -`.
"""

import argparse
import io
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

# Paths the Dockerfile reads. SwiftPM needs the whole manifest graph, including
# test target directories it declares.
BUILD_INPUTS = (
    "Package.swift",
    "Package.resolved",
    "Packages",
    "Sources",
    "Tests",
    "Vendor",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "ThirdPartyLicenses",
    "docs/linux.md",
    "Scripts/linux_headless_smoke.py",
)
CONTAINER_DIR = "Scripts/linux_agent_container"
# Container scripts are copied into the image even before they are committed.
CONTAINER_FILES = (
    "Dockerfile",
    "build_context.py",
    "entrypoint.sh",
    "extra_ca_env.sh",
    "import_credentials.py",
    "rpce-mcp.sh",
    "setup.sh",
)


def tracked_files(repo):
    output = subprocess.run(
        ["git", "-C", repo, "ls-files", "-z", "--cached", "--", *BUILD_INPUTS],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    return [path.decode("utf-8", "surrogateescape") for path in output.split(b"\0") if path]


class UnsafePath(Exception):
    """A build input path is not safely contained in the repository."""


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
# O_NONBLOCK: a FIFO or device swapped in for a file must not block the open;
# fstat then rejects it.
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK


def components(relative):
    parts = relative.split("/")
    if relative.startswith("/") or any(part in ("", ".", "..") for part in parts):
        raise UnsafePath("not a normalized repository-relative path")
    return parts


def read_entry(root_fd, relative):
    """Read one build input without following any symlink.

    Every parent directory is opened relative to the previous one with
    O_NOFOLLOW, so a symlinked or replaced ancestor cannot redirect the read
    outside the repository. The final component is either kept as a symlink
    (its target is recorded, never read) or opened with O_NOFOLLOW and checked
    with fstat. Returns None when the path does not exist.
    """
    parts = components(relative)
    fd = os.dup(root_fd)
    try:
        for index, part in enumerate(parts[:-1]):
            try:
                child = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                return None
            except OSError as error:
                # ELOOP: symlink; ENOTDIR: not a directory.
                ancestor = "/".join(parts[:index + 1])
                raise UnsafePath(f"ancestor {ancestor} is a symlink or not a directory ({error.strerror})") from None
            os.close(fd)
            fd = child
        name = parts[-1]
        try:
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(info.st_mode):
            try:
                target = os.readlink(name, dir_fd=fd)
            except OSError as error:
                raise UnsafePath(f"changed while being read ({error.strerror})") from None
            return ("symlink", target, info)
        if not stat.S_ISREG(info.st_mode):
            raise UnsafePath("is not a regular file or symlink")
        try:
            file_fd = os.open(name, FILE_FLAGS, dir_fd=fd)
        except OSError as error:
            raise UnsafePath(f"changed while being read ({error.strerror})") from None
        with os.fdopen(file_fd, "rb") as handle:
            opened = os.fstat(handle.fileno())
            if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                raise UnsafePath("was replaced while being read")
            data = handle.read()
        return ("file", data, opened)
    finally:
        os.close(fd)


def add(tar, root_fd, relative, missing_ok):
    entry_data = read_entry(root_fd, relative)
    if entry_data is None:
        if missing_ok:
            return False  # tracked file deleted in the working tree
        raise UnsafePath("is missing")
    kind, payload, info = entry_data
    entry = tarfile.TarInfo(relative)
    entry.mtime = int(info.st_mtime)
    entry.uid = entry.gid = 0
    entry.uname = entry.gname = "root"
    if kind == "symlink":
        entry.type = tarfile.SYMTYPE
        entry.linkname = payload
        entry.mode = 0o777
        tar.addfile(entry)
    else:
        # Size comes from the bytes actually read, so the archive stays
        # consistent even if the file changes size during the read.
        entry.size = len(payload)
        entry.mode = 0o755 if info.st_mode & 0o111 else 0o644
        tar.addfile(entry, io.BytesIO(payload))
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="print included paths instead of a tar stream")
    args = parser.parse_args()
    repo = subprocess.run(
        ["git", "-C", os.path.dirname(os.path.abspath(__file__)), "rev-parse", "--show-toplevel"],
        check=True, stdout=subprocess.PIPE, text=True,
    ).stdout.strip()

    paths = {path: True for path in tracked_files(repo) if not path.startswith(CONTAINER_DIR + "/")}
    for name in CONTAINER_FILES:
        paths[f"{CONTAINER_DIR}/{name}"] = False
    ordered = sorted(paths)

    if not args.list and sys.stdout.isatty():
        raise SystemExit("build_context: refusing to write a tar stream to a terminal; use --list")
    root_fd = os.open(repo, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        if args.list:
            for path in ordered:
                try:
                    if read_entry(root_fd, path) is not None:
                        print(path)
                except UnsafePath as error:
                    print(f"build_context: refusing {path}: {error}", file=sys.stderr)
                    return 1
            return 0
        # Assemble the whole archive before writing any of it, so a refusal
        # never leaves docker with a truncated context it could still build.
        with tempfile.TemporaryFile(prefix="rpce-build-context-") as spool:
            try:
                with tarfile.open(fileobj=spool, mode="w", format=tarfile.PAX_FORMAT) as tar:
                    for path in ordered:
                        add(tar, root_fd, path, missing_ok=paths[path])
            except UnsafePath as error:
                print(f"build_context: refusing {path}: {error}; no build context was written", file=sys.stderr)
                return 1
            spool.seek(0)
            shutil.copyfileobj(spool, sys.stdout.buffer)
            sys.stdout.buffer.flush()
        return 0
    finally:
        os.close(root_fd)


if __name__ == "__main__":
    sys.exit(main())
