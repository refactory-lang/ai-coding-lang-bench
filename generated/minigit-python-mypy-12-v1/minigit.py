#!/usr/bin/env python3
"""MiniGit: A minimal version control system."""

import os
import sys
import time


def minihash(data: bytes) -> str:
    """Compute MiniHash (FNV-1a variant, 64-bit, 16-char hex)."""
    h: int = 1469598103934665603
    for b in data:
        h ^= b
        h = (h * 1099511628211) % (2**64)
    return format(h, "016x")


def cmd_init() -> None:
    """Initialize a new MiniGit repository."""
    if os.path.isdir(".minigit"):
        print("Repository already initialized")
        return
    os.makedirs(".minigit/objects", exist_ok=True)
    os.makedirs(".minigit/commits", exist_ok=True)
    with open(".minigit/index", "w") as f:
        pass
    with open(".minigit/HEAD", "w") as f:
        pass


def cmd_add(filename: str) -> None:
    """Stage a file."""
    if not os.path.isfile(filename):
        print("File not found")
        sys.exit(1)

    with open(filename, "rb") as f:
        data: bytes = f.read()

    h: str = minihash(data)
    obj_path: str = os.path.join(".minigit", "objects", h)
    with open(obj_path, "wb") as f:
        f.write(data)

    # Read current index
    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "r") as f:
        lines: list[str] = [line.strip() for line in f if line.strip()]

    if filename not in lines:
        lines.append(filename)
        with open(index_path, "w") as f:
            f.write("\n".join(lines) + "\n")


def cmd_commit(message: str) -> None:
    """Create a commit."""
    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "r") as f:
        files: list[str] = [line.strip() for line in f if line.strip()]

    if not files:
        print("Nothing to commit")
        sys.exit(1)

    # Read HEAD
    head_path: str = os.path.join(".minigit", "HEAD")
    with open(head_path, "r") as f:
        parent: str = f.read().strip()

    parent_str: str = parent if parent else "NONE"
    timestamp: int = int(time.time())

    # Build file entries sorted lexicographically
    sorted_files: list[str] = sorted(files)
    file_entries: list[str] = []
    for fn in sorted_files:
        with open(fn, "rb") as f:
            data: bytes = f.read()
        h: str = minihash(data)
        file_entries.append(f"{fn} {h}")

    commit_content: str = (
        f"parent: {parent_str}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
        + "\n".join(file_entries)
        + "\n"
    )

    commit_hash: str = minihash(commit_content.encode("utf-8"))

    # Write commit file
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    with open(commit_path, "w") as f:
        f.write(commit_content)

    # Update HEAD
    with open(head_path, "w") as f:
        f.write(commit_hash)

    # Clear index
    with open(index_path, "w") as f:
        pass

    print(f"Committed {commit_hash}")


def cmd_log() -> None:
    """Show commit log."""
    head_path: str = os.path.join(".minigit", "HEAD")
    with open(head_path, "r") as f:
        current: str = f.read().strip()

    if not current:
        print("No commits")
        return

    first: bool = True
    while current:
        if not first:
            print()
        first = False

        commit_path: str = os.path.join(".minigit", "commits", current)
        with open(commit_path, "r") as f:
            content: str = f.read()

        # Parse commit
        parent_hash: str = ""
        timestamp_str: str = ""
        message: str = ""
        for line in content.split("\n"):
            if line.startswith("parent: "):
                parent_hash = line[len("parent: "):]
            elif line.startswith("timestamp: "):
                timestamp_str = line[len("timestamp: "):]
            elif line.startswith("message: "):
                message = line[len("message: "):]

        print(f"commit {current}")
        print(f"Date: {timestamp_str}")
        print(f"Message: {message}")

        if parent_hash == "NONE":
            break
        current = parent_hash


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
