"""MiniGit: A minimal version control system."""

import os
import sys
import time


def minihash(data: bytes) -> str:
    """Compute MiniHash (FNV-1a variant, 64-bit, 16-char hex)."""
    h: int = 1469598103934665603
    mod: int = 2**64
    for b in data:
        h ^= b
        h = (h * 1099511628211) % mod
    return format(h, "016x")


def get_minigit_dir() -> str:
    """Return path to .minigit directory."""
    return os.path.join(os.getcwd(), ".minigit")


def cmd_init() -> None:
    """Initialize a new repository."""
    mgdir: str = get_minigit_dir()
    if os.path.isdir(mgdir):
        print("Repository already initialized")
        return
    os.makedirs(os.path.join(mgdir, "objects"))
    os.makedirs(os.path.join(mgdir, "commits"))
    with open(os.path.join(mgdir, "index"), "w") as f:
        f.write("")
    with open(os.path.join(mgdir, "HEAD"), "w") as f:
        f.write("")


def cmd_add(filename: str) -> None:
    """Stage a file."""
    if not os.path.isfile(filename):
        print("File not found")
        sys.exit(1)

    with open(filename, "rb") as f:
        content: bytes = f.read()

    h: str = minihash(content)
    obj_path: str = os.path.join(get_minigit_dir(), "objects", h)
    with open(obj_path, "wb") as f:
        f.write(content)

    index_path: str = os.path.join(get_minigit_dir(), "index")
    existing: list[str] = []
    with open(index_path, "r") as f:
        existing = [line.strip() for line in f if line.strip()]

    if filename not in existing:
        existing.append(filename)
        with open(index_path, "w") as f:
            for name in existing:
                f.write(name + "\n")


def cmd_commit(message: str) -> None:
    """Create a commit."""
    mgdir: str = get_minigit_dir()
    index_path: str = os.path.join(mgdir, "index")

    with open(index_path, "r") as f:
        staged: list[str] = [line.strip() for line in f if line.strip()]

    if not staged:
        print("Nothing to commit")
        sys.exit(1)

    head_path: str = os.path.join(mgdir, "HEAD")
    with open(head_path, "r") as f:
        parent: str = f.read().strip()

    parent_str: str = parent if parent else "NONE"

    timestamp = int(time.time())

    file_entries: list[str] = []
    for fname in sorted(staged):
        with open(fname, "rb") as f:
            content: bytes = f.read()
        h: str = minihash(content)
        file_entries.append(f"{fname} {h}")

    commit_content: str = (
        f"parent: {parent_str}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
    )
    for entry in file_entries:
        commit_content += entry + "\n"

    commit_hash: str = minihash(commit_content.encode())

    with open(os.path.join(mgdir, "commits", commit_hash), "w") as f:
        f.write(commit_content)

    with open(head_path, "w") as f:
        f.write(commit_hash)

    with open(index_path, "w") as f:
        f.write("")

    print(f"Committed {commit_hash}")


def cmd_log() -> None:
    """Show commit log."""
    mgdir: str = get_minigit_dir()
    head_path: str = os.path.join(mgdir, "HEAD")

    with open(head_path, "r") as f:
        current: str = f.read().strip()

    if not current:
        print("No commits")
        return

    first: bool = True
    while current:
        commit_path: str = os.path.join(mgdir, "commits", current)
        with open(commit_path, "r") as f:
            lines: list[str] = f.readlines()

        parent: str = ""
        timestamp: str = ""
        message: str = ""
        for line in lines:
            line_s: str = line.strip()
            if line_s.startswith("parent: "):
                parent = line_s[len("parent: "):]
            elif line_s.startswith("timestamp: "):
                timestamp = line_s[len("timestamp: "):]
            elif line_s.startswith("message: "):
                message = line_s[len("message: "):]

        if not first:
            print()
        first = False

        print(f"commit {current}")
        print(f"Date: {timestamp}")
        print(f"Message: {message}")

        if parent == "NONE":
            current = ""
        else:
            current = parent


def main() -> None:
    """Entry point."""
    if len(sys.argv) < 2:
        print("Usage: minigit <command>")
        sys.exit(1)

    command: str = sys.argv[1]

    if command == "init":
        cmd_init()
    elif command == "add":
        if len(sys.argv) < 3:
            print("Usage: minigit add <file>")
            sys.exit(1)
        cmd_add(sys.argv[2])
    elif command == "commit":
        if len(sys.argv) < 4 or sys.argv[2] != "-m":
            print("Usage: minigit commit -m <message>")
            sys.exit(1)
        cmd_commit(sys.argv[3])
    elif command == "log":
        cmd_log()
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
