#!/usr/bin/env python3
"""MiniGit: A minimal version control system."""

import os
import sys
import time


MINIGIT_DIR: str = ".minigit"
OBJECTS_DIR: str = os.path.join(MINIGIT_DIR, "objects")
COMMITS_DIR: str = os.path.join(MINIGIT_DIR, "commits")
INDEX_FILE: str = os.path.join(MINIGIT_DIR, "index")
HEAD_FILE: str = os.path.join(MINIGIT_DIR, "HEAD")


def minihash(data: bytes) -> str:
    """Compute MiniHash (FNV-1a variant, 64-bit, 16-char hex)."""
    h: int = 1469598103934665603
    for b in data:
        h = h ^ b
        h = (h * 1099511628211) % (2 ** 64)
    return format(h, "016x")


def cmd_init() -> None:
    """Initialize a new repository."""
    if os.path.isdir(MINIGIT_DIR):
        print("Repository already initialized")
        return
    os.makedirs(OBJECTS_DIR)
    os.makedirs(COMMITS_DIR)
    with open(INDEX_FILE, "w") as f:
        pass
    with open(HEAD_FILE, "w") as f:
        pass


def cmd_add(filename: str) -> None:
    """Stage a file."""
    if not os.path.isfile(filename):
        print("File not found")
        sys.exit(1)

    with open(filename, "rb") as f:
        content: bytes = f.read()

    blob_hash: str = minihash(content)
    blob_path: str = os.path.join(OBJECTS_DIR, blob_hash)

    with open(blob_path, "wb") as f:
        f.write(content)

    # Read current index
    with open(INDEX_FILE, "r") as f:
        lines: list[str] = f.read().splitlines()

    if filename not in lines:
        lines.append(filename)
        with open(INDEX_FILE, "w") as f:
            f.write("\n".join(lines) + "\n")


def cmd_commit(message: str) -> None:
    """Create a commit."""
    with open(INDEX_FILE, "r") as f:
        lines: list[str] = [line for line in f.read().splitlines() if line]

    if not lines:
        print("Nothing to commit")
        sys.exit(1)

    # Read parent
    with open(HEAD_FILE, "r") as f:
        parent: str = f.read().strip()

    if not parent:
        parent = "NONE"

    timestamp: int = int(time.time())

    # Build file entries sorted lexicographically
    sorted_files: list[str] = sorted(lines)
    file_entries: list[str] = []
    for fname in sorted_files:
        with open(fname, "rb") as f:
            content: bytes = f.read()
        blob_hash: str = minihash(content)
        file_entries.append(f"{fname} {blob_hash}")

    commit_text: str = (
        f"parent: {parent}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
        + "\n".join(file_entries)
        + "\n"
    )

    commit_hash: str = minihash(commit_text.encode())
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)

    with open(commit_path, "w") as f:
        f.write(commit_text)

    with open(HEAD_FILE, "w") as f:
        f.write(commit_hash)

    # Clear index
    with open(INDEX_FILE, "w") as f:
        pass

    print(f"Committed {commit_hash}")


def cmd_log() -> None:
    """Show commit log."""
    with open(HEAD_FILE, "r") as f:
        current: str = f.read().strip()

    if not current:
        print("No commits")
        return

    first: bool = True
    while current and current != "NONE":
        commit_path: str = os.path.join(COMMITS_DIR, current)
        with open(commit_path, "r") as f:
            content: str = f.read()

        # Parse commit
        timestamp: str = ""
        message: str = ""
        for line in content.splitlines():
            if line.startswith("timestamp: "):
                timestamp = line[len("timestamp: "):]
            elif line.startswith("message: "):
                message = line[len("message: "):]
            elif line.startswith("parent: "):
                parent: str = line[len("parent: "):]

        if not first:
            print()
        first = False

        print(f"commit {current}")
        print(f"Date: {timestamp}")
        print(f"Message: {message}")

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
