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


def parse_commit(content: str) -> tuple[str, str, str, list[tuple[str, str]]]:
    """Parse commit content, return (parent, timestamp, message, files)."""
    parent: str = "NONE"
    timestamp: str = ""
    message: str = ""
    files: list[tuple[str, str]] = []
    in_files: bool = False
    for line in content.splitlines():
        if in_files:
            parts: list[str] = line.split(" ", 1)
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


def cmd_status() -> None:
    """Show staged files."""
    with open(INDEX_FILE, "r") as f:
        lines: list[str] = [line for line in f.read().splitlines() if line]

    print("Staged files:")
    if not lines:
        print("(none)")
    else:
        for line in lines:
            print(line)


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

        parent, timestamp, message, _ = parse_commit(content)

        if not first:
            print()
        first = False

        print(f"commit {current}")
        print(f"Date: {timestamp}")
        print(f"Message: {message}")

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
    """Checkout a commit."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    _, _, _, files = parse_commit(content)

    for fname, blob_hash in files:
        blob_path: str = os.path.join(OBJECTS_DIR, blob_hash)
        with open(blob_path, "rb") as f:
            blob_content: bytes = f.read()
        with open(fname, "wb") as f:
            f.write(blob_content)

    with open(HEAD_FILE, "w") as f:
        f.write(commit_hash)

    with open(INDEX_FILE, "w") as f:
        pass

    print(f"Checked out {commit_hash}")


def cmd_reset(commit_hash: str) -> None:
    """Reset HEAD to a commit."""
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
    """Remove a file from the index."""
    with open(INDEX_FILE, "r") as f:
        lines: list[str] = [line for line in f.read().splitlines() if line]

    if filename not in lines:
        print("File not in index")
        sys.exit(1)

    lines.remove(filename)
    with open(INDEX_FILE, "w") as f:
        if lines:
            f.write("\n".join(lines) + "\n")


def cmd_show(commit_hash: str) -> None:
    """Show commit details."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    _, timestamp, message, files = parse_commit(content)

    print(f"commit {commit_hash}")
    print(f"Date: {timestamp}")
    print(f"Message: {message}")
    print("Files:")
    for fname, blob_hash in files:
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
