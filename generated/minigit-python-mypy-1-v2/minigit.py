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


def cmd_status() -> None:
    """Show staged files."""
    with open(INDEX_FILE, "r") as f:
        content: str = f.read()

    entries: list[str] = [line for line in content.splitlines() if line]

    print("Staged files:")
    if entries:
        for entry in entries:
            print(entry)
    else:
        print("(none)")


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


def _parse_commit_files(commit_hash: str) -> dict[str, str]:
    """Parse a commit file and return a dict of filename -> blob_hash."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    files: dict[str, str] = {}
    in_files: bool = False
    for line in content.splitlines():
        if line == "files:":
            in_files = True
            continue
        if in_files and line:
            parts: list[str] = line.split()
            if len(parts) == 2:
                files[parts[0]] = parts[1]

    return files


def cmd_diff(commit1: str, commit2: str) -> None:
    """Compare two commits."""
    files1: dict[str, str] = _parse_commit_files(commit1)
    files2: dict[str, str] = _parse_commit_files(commit2)

    all_files: list[str] = sorted(set(list(files1.keys()) + list(files2.keys())))

    for fname in all_files:
        if fname not in files1:
            print(f"Added: {fname}")
        elif fname not in files2:
            print(f"Removed: {fname}")
        elif files1[fname] != files2[fname]:
            print(f"Modified: {fname}")


def cmd_checkout(commit_hash: str) -> None:
    """Checkout a commit: restore files and update HEAD."""
    files: dict[str, str] = _parse_commit_files(commit_hash)

    for fname, blob_hash in files.items():
        blob_path: str = os.path.join(OBJECTS_DIR, blob_hash)
        with open(blob_path, "rb") as f:
            data: bytes = f.read()
        with open(fname, "wb") as f:
            f.write(data)

    with open(HEAD_FILE, "w") as f:
        f.write(commit_hash)

    with open(INDEX_FILE, "w") as f:
        pass

    print(f"Checked out {commit_hash}")


def cmd_reset(commit_hash: str) -> None:
    """Reset HEAD to a commit without changing working directory."""
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
        content: str = f.read()

    entries: list[str] = [line for line in content.splitlines() if line]

    if filename not in entries:
        print("File not in index")
        sys.exit(1)

    entries.remove(filename)

    with open(INDEX_FILE, "w") as f:
        f.write("\n".join(entries) + "\n" if entries else "")


def cmd_show(commit_hash: str) -> None:
    """Show details of a commit."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    timestamp_str: str = ""
    message_str: str = ""
    file_lines: list[str] = []
    in_files: bool = False

    for line in content.splitlines():
        if line.startswith("timestamp: "):
            timestamp_str = line[len("timestamp: "):]
        elif line.startswith("message: "):
            message_str = line[len("message: "):]
        elif line == "files:":
            in_files = True
        elif in_files and line:
            file_lines.append(line)

    print(f"commit {commit_hash}")
    print(f"Date: {timestamp_str}")
    print(f"Message: {message_str}")
    print("Files:")
    for fl in sorted(file_lines):
        print(f"  {fl}")


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
