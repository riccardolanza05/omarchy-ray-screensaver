#!/usr/bin/env python3
"""Read or write the stay-awake marker without ever resolving an
attacker-plantable path by name.

The previous fix (FileView + QSaveFile atomicWrites) made the final
write/rename atomic, but QSaveFile still opens ~/.local/state/omarchy/indicators
by *pathname*: if any ancestor component (indicators, omarchy, state, or
.local) is swapped for a symlink before this runs, the kernel happily follows
it and the "atomic" write lands wherever the symlink points. Atomicity of the
last step does not help when the path leading to it isn't trustworthy.

The fix is to never resolve a path by name at all: walk from a trusted
starting directory (a fd we just opened) one component at a time, opening
each next component with O_NOFOLLOW *relative to the fd of its already-opened,
already-validated parent* (dir_fd=). A symlink at any level makes that open()
fail outright (ELOOP) instead of being followed -- there is no separate
check-then-open step for a race to land in, because the open call itself is
the check. Each directory is also required to be owned by the invoking user
before we descend into or write through it.

Usage:
  persist-stay-awake.py load        -> prints "on" or "off" to stdout
  persist-stay-awake.py on|off      -> persists the value atomically
"""
import errno
import os
import stat
import sys

STATE_PATH_COMPONENTS = (".local", "state", "omarchy", "indicators")
MARKER_NAME = "stay-awake"


def die(message):
    print("persist-stay-awake: " + message, file=sys.stderr)
    sys.exit(1)


def open_validated_dir(parent_fd, name):
    """Open `name` under `parent_fd`, creating it if absent, refusing if it
    is a symlink or not an owned directory. Returns a new fd; never follows
    a symlink at this path component."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    except FileNotFoundError:
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            pass  # lost a benign creation race; fall through and open+validate
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    except NotADirectoryError:
        die(name + " exists and is not a directory")
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            die(name + " is a symlink, refusing to follow it")
        raise

    st = os.fstat(fd)
    if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
        os.close(fd)
        die(name + " is not a plain directory")
    if st.st_uid != os.getuid():
        os.close(fd)
        die(name + " is not owned by the current user")
    return fd


def open_state_dir_fd():
    home = os.environ.get("HOME")
    if not home:
        die("HOME is not set")
    fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    st = os.fstat(fd)
    if st.st_uid != os.getuid():
        os.close(fd)
        die("HOME is not owned by the current user")
    for component in STATE_PATH_COMPONENTS:
        next_fd = open_validated_dir(fd, component)
        os.close(fd)
        fd = next_fd
    return fd


def load(dir_fd):
    try:
        fd = os.open(MARKER_NAME, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
    except FileNotFoundError:
        print("off")
        return
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            die(MARKER_NAME + " is a symlink, refusing to follow it")
        raise
    try:
        data = os.read(fd, 16)
    finally:
        os.close(fd)
    print("on" if data.strip() == b"on" else "off")


def persist(dir_fd, value):
    tmp_name = ".%s.tmp-%d" % (MARKER_NAME, os.getpid())
    fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
    try:
        os.write(fd, (value + "\n").encode("ascii"))
        os.fsync(fd)
    finally:
        os.close(fd)
    # Rename is resolved purely against dir_fd (already validated above), not
    # by walking the pathname again -- nothing between validation and this
    # replace ever re-resolves a name through the filesystem.
    os.replace(tmp_name, MARKER_NAME, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)


def main(argv):
    if len(argv) != 2 or argv[1] not in ("load", "on", "off"):
        die("usage: persist-stay-awake.py load|on|off")

    dir_fd = open_state_dir_fd()
    try:
        if argv[1] == "load":
            load(dir_fd)
        else:
            persist(dir_fd, argv[1])
    finally:
        os.close(dir_fd)


if __name__ == "__main__":
    main(sys.argv)
