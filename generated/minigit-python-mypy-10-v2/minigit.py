#!/usr/bin/env python3
"""MiniGit: A minimal version control system."""

import os
import sys
import time
from pathlib import Path


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
        h ^= b
        h = (h * 1099511628211) % mod
    return format(h, "016x")


def parse_commit(content: str) -> tuple[str, str, str, list[tuple[str, str]]]:
    """Parse commit content into (parent, timestamp, message, files)."""
    parent: str = ""
    timestamp: str = ""
    message: str = ""
    files: list[tuple[str, str]] = []
    in_files: bool = False

    for line in content.split("\n"):
        if in_files:
            stripped: str = line.strip()
            if stripped:
                parts: list[str] = stripped.split(" ", 1)
                if len(parts) == 2:
                    files.append((parts[0], parts[1]))
        elif line.startswith("parent: "):
            parent = line[len("parent: "):]
        elif line.startswith("timestamp: "):
            timestamp = line[len("timestamp: "):]
        elif line.startswith("message: "):
            message = line[len("message: "):]
        elif line == "files:":
            in_files = True

    return parent, timestamp, message, files


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
    """Add a file to the staging area."""
    if not os.path.isfile(filename):
        print("File not found")
        sys.exit(1)

    with open(filename, "rb") as f:
        data: bytes = f.read()

    blob_hash: str = minihash(data)
    blob_path: str = os.path.join(OBJECTS_DIR, blob_hash)

    with open(blob_path, "wb") as f:
        f.write(data)

    with open(INDEX_FILE, "r") as f:
        lines: list[str] = [line.strip() for line in f if line.strip()]

    if filename not in lines:
        lines.append(filename)
        with open(INDEX_FILE, "w") as f:
            for line in lines:
                f.write(line + "\n")


def cmd_commit(message: str) -> None:
    """Create a commit from staged files."""
    with open(INDEX_FILE, "r") as f:
        staged: list[str] = [line.strip() for line in f if line.strip()]

    if not staged:
        print("Nothing to commit")
        sys.exit(1)

    with open(HEAD_FILE, "r") as f:
        parent: str = f.read().strip()

    parent_str: str = parent if parent else "NONE"
    timestamp: int = int(time.time())

    sorted_files: list[str] = sorted(staged)
    file_entries: list[str] = []
    for fname in sorted_files:
        with open(fname, "rb") as f:
            data: bytes = f.read()
        blob_hash: str = minihash(data)
        file_entries.append(f"{fname} {blob_hash}")

    commit_content: str = (
        f"parent: {parent_str}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
    )
    for entry in file_entries:
        commit_content += entry + "\n"

    commit_hash: str = minihash(commit_content.encode("utf-8"))
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)

    with open(commit_path, "w") as f:
        f.write(commit_content)

    with open(HEAD_FILE, "w") as f:
        f.write(commit_hash)

    with open(INDEX_FILE, "w") as f:
        pass

    print(f"Committed {commit_hash}")


def cmd_status() -> None:
    """Show staged files."""
    with open(INDEX_FILE, "r") as f:
        staged: list[str] = [line.strip() for line in f if line.strip()]

    print("Staged files:")
    if staged:
        for fname in staged:
            print(fname)
    else:
        print("(none)")


def cmd_log() -> None:
    """Show commit log."""
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

        parent, timestamp_str, message_str, _ = parse_commit(content)

        if not first:
            print()
        first = False

        print(f"commit {current}")
        print(f"Date: {timestamp_str}")
        print(f"Message: {message_str}")

        if parent == "NONE" or not parent:
            break
        current = parent


def cmd_diff(commit1: str, commit2: str) -> None:
    """Compare two commits."""
    path1: str = os.path.join(COMMITS_DIR, commit1)
    path2: str = os.path.join(COMMITS_DIR, commit2)

    if not os.path.isfile(path1) or not os.path.isfile(path2):
        print("Invalid commit")
        sys.exit(1)

    with open(path1, "r") as f:
        content1: str = f.read()
    with open(path2, "r") as f:
        content2: str = f.read()

    _, _, _, files1 = parse_commit(content1)
    _, _, _, files2 = parse_commit(content2)

    map1: dict[str, str] = {name: blob for name, blob in files1}
    map2: dict[str, str] = {name: blob for name, blob in files2}

    all_files: list[str] = sorted(set(list(map1.keys()) + list(map2.keys())))

    for fname in all_files:
        if fname not in map1 and fname in map2:
            print(f"Added: {fname}")
        elif fname in map1 and fname not in map2:
            print(f"Removed: {fname}")
        elif fname in map1 and fname in map2 and map1[fname] != map2[fname]:
            print(f"Modified: {fname}")


def cmd_checkout(commit_hash: str) -> None:
    """Checkout a commit, restoring working directory files."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)

    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    _, _, _, files = parse_commit(content)

    for fname, blob_hash in files:
        blob_path: str = os.path.join(OBJECTS_DIR, blob_hash)
        with open(blob_path, "rb") as bf:
            blob_data: bytes = bf.read()
        with open(fname, "wb") as wf:
            wf.write(blob_data)

    with open(HEAD_FILE, "w") as f:
        f.write(commit_hash)

    with open(INDEX_FILE, "w") as f:
        pass

    print(f"Checked out {commit_hash}")


def cmd_reset(commit_hash: str) -> None:
    """Reset HEAD to a commit without modifying working directory."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)

    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(HEAD_FILE, "w") as f:
        f.write(commit_hash)

    with open(INDEX_FILE, "w") as f:
        pass

    print(f"Reset to {commit_hash}")


def cmd_rm(filename: str) -> None:
    """Remove a file from the staging index."""
    with open(INDEX_FILE, "r") as f:
        lines: list[str] = [line.strip() for line in f if line.strip()]

    if filename not in lines:
        print("File not in index")
        sys.exit(1)

    lines.remove(filename)
    with open(INDEX_FILE, "w") as f:
        for line in lines:
            f.write(line + "\n")


def cmd_show(commit_hash: str) -> None:
    """Show details of a commit."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)

    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    _, timestamp_str, message_str, files = parse_commit(content)

    print(f"commit {commit_hash}")
    print(f"Date: {timestamp_str}")
    print(f"Message: {message_str}")
    print("Files:")
    for fname, blob_hash in sorted(files, key=lambda x: x[0]):
        print(f"  {fname} {blob_hash}")


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
    elif command == "status":
        cmd_status()
    elif command == "log":
        cmd_log()
    elif command == "diff":
        if len(sys.argv) < 4:
            print("Usage: minigit diff <commit1> <commit2>")
            sys.exit(1)
        cmd_diff(sys.argv[2], sys.argv[3])
    elif command == "checkout":
        if len(sys.argv) < 3:
            print("Usage: minigit checkout <commit_hash>")
            sys.exit(1)
        cmd_checkout(sys.argv[2])
    elif command == "reset":
        if len(sys.argv) < 3:
            print("Usage: minigit reset <commit_hash>")
            sys.exit(1)
        cmd_reset(sys.argv[2])
    elif command == "rm":
        if len(sys.argv) < 3:
            print("Usage: minigit rm <file>")
            sys.exit(1)
        cmd_rm(sys.argv[2])
    elif command == "show":
        if len(sys.argv) < 3:
            print("Usage: minigit show <commit_hash>")
            sys.exit(1)
        cmd_show(sys.argv[2])
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
