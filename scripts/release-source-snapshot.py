#!/usr/bin/env python3
"""Emit a bounded digest of Git tracked plus nonignored-untracked source inputs."""

import hashlib
import os
import stat
import subprocess
import sys
import unicodedata

MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_FILES = 100_000
MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024


def fail(message: str) -> None:
    print(f"source snapshot failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def git_paths(root: str, arguments: list[str]) -> list[bytes]:
    result = subprocess.run(
        ["/usr/bin/git", "-C", root, *arguments], capture_output=True, check=False
    )
    if result.returncode:
        fail("git enumeration failed")
    values = result.stdout.split(b"\0")
    if values and values[-1] == b"":
        values.pop()
    return values


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: release-source-snapshot.py REPOSITORY")
    root = os.path.realpath(sys.argv[1])
    if not os.path.isdir(os.path.join(root, ".git")):
        fail("repository root is invalid")
    raw = git_paths(root, ["ls-files", "-z"]) + git_paths(
        root, ["ls-files", "--others", "--exclude-standard", "-z"]
    )
    if len(raw) > MAX_FILES:
        fail("file-count bound exceeded")
    paths: list[tuple[bytes, str]] = []
    normalized: set[str] = set()
    for encoded in raw:
        try:
            path = encoded.decode("utf-8", "strict")
        except UnicodeDecodeError:
            fail("non-UTF-8 path")
        if not path or path.startswith("/") or "\0" in path or ".." in path.split("/"):
            fail("unsafe path")
        # A tracked path deleted in the worktree is intentionally absent from the
        # source union; the resulting count/digest still binds that deletion.
        if not os.path.lexists(os.path.join(root, path)):
            continue
        key = unicodedata.normalize("NFC", path).casefold()
        if key in normalized:
            fail("duplicate, case-fold, or Unicode path collision")
        normalized.add(key)
        paths.append((encoded, path))
    paths.sort(key=lambda value: value[0])

    digest = hashlib.sha256(b"elysium-release-source-v1\0")
    total = 0
    identities: set[tuple[int, int]] = set()
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for encoded, path in paths:
            flags = os.O_RDONLY | os.O_CLOEXEC
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            try:
                fd = os.open(path, flags, dir_fd=root_fd)
            except OSError:
                fail("unreadable or unsafe input")
            try:
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                    fail("non-regular or linked input")
                if before.st_size > MAX_FILE_BYTES:
                    fail("per-file bound exceeded")
                identity = (before.st_dev, before.st_ino)
                if identity in identities:
                    fail("hard-link alias")
                identities.add(identity)
                chunks: list[bytes] = []
                remaining = before.st_size
                while remaining:
                    chunk = os.read(fd, min(1024 * 1024, remaining))
                    if not chunk:
                        fail("short read")
                    chunks.append(chunk)
                    remaining -= len(chunk)
                if os.read(fd, 1):
                    fail("input grew during enumeration")
                after = os.fstat(fd)
                if (before.st_dev, before.st_ino, before.st_mode, before.st_size,
                    before.st_mtime_ns, before.st_ctime_ns) != (
                    after.st_dev, after.st_ino, after.st_mode, after.st_size,
                    after.st_mtime_ns, after.st_ctime_ns):
                    fail("input changed during enumeration")
                data = b"".join(chunks)
                total += len(data)
                if total > MAX_TOTAL_BYTES:
                    fail("aggregate bound exceeded")
                mode = b"100755" if before.st_mode & 0o111 else b"100644"
                digest.update(encoded + b"\0" + mode + b"\0")
                digest.update(str(len(data)).encode("ascii") + b"\0" + data + b"\0")
            finally:
                os.close(fd)
    finally:
        os.close(root_fd)
    print(f"sha256={digest.hexdigest()} count={len(paths)} bytes={total}")


if __name__ == "__main__":
    main()
