#!/usr/bin/env python3
"""MiniGit: a minimal version control system."""

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
    mod: int = 2 ** 64
    for b in data:
        h = h ^ b
        h = (h * 1099511628211) % mod
    return format(h, "016x")


def cmd_init() -> None:
    """Initialize a new minigit repository."""
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
        data: bytes = f.read()

    blob_hash: str = minihash(data)
    blob_path: str = os.path.join(OBJECTS_DIR, blob_hash)

    with open(blob_path, "wb") as f:
        f.write(data)

    # Read current index
    with open(INDEX_FILE, "r") as f:
        content: str = f.read()

    entries: list[str] = [line for line in content.splitlines() if line]

    if filename not in entries:
        entries.append(filename)

    with open(INDEX_FILE, "w") as f:
        f.write("\n".join(entries) + "\n" if entries else "")


def cmd_commit(message: str) -> None:
    """Create a commit from staged files."""
    # Read index
    with open(INDEX_FILE, "r") as f:
        content: str = f.read()

    entries: list[str] = [line for line in content.splitlines() if line]

    if not entries:
        print("Nothing to commit")
        sys.exit(1)

    # Read HEAD
    with open(HEAD_FILE, "r") as f:
        head: str = f.read().strip()

    parent: str = head if head else "NONE"
    timestamp: int = int(time.time())

    # Build file list sorted lexicographically
    sorted_files: list[str] = sorted(entries)
    file_lines: list[str] = []
    for fname in sorted_files:
        with open(fname, "rb") as f:
            data: bytes = f.read()
        blob_hash: str = minihash(data)
        file_lines.append(f"{fname} {blob_hash}")

    # Build commit content
    commit_content: str = (
        f"parent: {parent}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
        + "\n".join(file_lines) + "\n"
    )

    commit_hash: str = minihash(commit_content.encode("utf-8"))
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)

    with open(commit_path, "w") as f:
        f.write(commit_content)

    # Update HEAD
    with open(HEAD_FILE, "w") as f:
        f.write(commit_hash)

    # Clear index
    with open(INDEX_FILE, "w") as f:
        pass

    print(f"Committed {commit_hash}")


def cmd_log() -> None:
    """Show commit log, most recent first."""
    with open(HEAD_FILE, "r") as f:
        current: str = f.read().strip()

    if not current:
        print("No commits")
        return

    first: bool = True
    while current:
        commit_path: str = os.path.join(COMMITS_DIR, current)
        with open(commit_path, "r") as f:
            content: str = f.read()

        # Parse commit
        lines: list[str] = content.splitlines()
        parent_hash: str = ""
        timestamp_str: str = ""
        message_str: str = ""

        for line in lines:
            if line.startswith("parent: "):
                parent_hash = line[len("parent: "):]
            elif line.startswith("timestamp: "):
                timestamp_str = line[len("timestamp: "):]
            elif line.startswith("message: "):
                message_str = line[len("message: "):]

        if not first:
            print()
        first = False

        print(f"commit {current}")
        print(f"Date: {timestamp_str}")
        print(f"Message: {message_str}")

        if parent_hash == "NONE" or not parent_hash:
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
            print('Usage: minigit commit -m "<message>"')
            sys.exit(1)
        cmd_commit(sys.argv[3])
    elif command == "log":
        cmd_log()
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
