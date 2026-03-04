#!/usr/bin/env python3
"""MiniGit: A minimal version control system."""

import os
import sys


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
        content: bytes = f.read()

    blob_hash: str = minihash(content)
    blob_path: str = os.path.join(OBJECTS_DIR, blob_hash)

    with open(blob_path, "wb") as f:
        f.write(content)

    # Read existing index entries
    entries: list[str] = []
    with open(INDEX_FILE, "r") as f:
        for line in f:
            stripped: str = line.strip()
            if stripped:
                entries.append(stripped)

    if filename not in entries:
        entries.append(filename)

    with open(INDEX_FILE, "w") as f:
        for entry in entries:
            f.write(entry + "\n")


def cmd_commit(message: str) -> None:
    """Create a commit from staged files."""
    # Read index
    entries: list[str] = []
    with open(INDEX_FILE, "r") as f:
        for line in f:
            stripped: str = line.strip()
            if stripped:
                entries.append(stripped)

    if not entries:
        print("Nothing to commit")
        sys.exit(1)

    # Read HEAD
    with open(HEAD_FILE, "r") as f:
        parent: str = f.read().strip()

    parent_str: str = parent if parent else "NONE"

    # Get timestamp
    timestamp: int = int(os.environ.get("MINIGIT_TIMESTAMP", str(int(__import__("time").time()))))

    # Sort filenames
    sorted_entries: list[str] = sorted(entries)

    # Build file lines with blob hashes
    file_lines: list[str] = []
    for entry in sorted_entries:
        with open(entry, "rb") as f:
            content: bytes = f.read()
        blob_hash: str = minihash(content)
        file_lines.append(f"{entry} {blob_hash}")

    # Build commit content
    commit_content: str = (
        f"parent: {parent_str}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
    )
    for fl in file_lines:
        commit_content += fl + "\n"

    # Hash commit
    commit_hash: str = minihash(commit_content.encode("utf-8"))

    # Write commit file
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
    entries: list[str] = []
    with open(INDEX_FILE, "r") as f:
        for line in f:
            stripped: str = line.strip()
            if stripped:
                entries.append(stripped)

    print("Staged files:")
    if not entries:
        print("(none)")
    else:
        for entry in entries:
            print(entry)


def cmd_log() -> None:
    """Show commit log."""
    with open(HEAD_FILE, "r") as f:
        current: str = f.read().strip()

    if not current:
        print("No commits")
        return

    while current and current != "NONE":
        commit_path: str = os.path.join(COMMITS_DIR, current)
        with open(commit_path, "r") as f:
            lines: list[str] = f.readlines()

        # Parse commit
        timestamp: str = ""
        message: str = ""
        for line in lines:
            if line.startswith("timestamp: "):
                timestamp = line[len("timestamp: "):].strip()
            elif line.startswith("message: "):
                message = line[len("message: "):].strip()

        print(f"commit {current}")
        print(f"Date: {timestamp}")
        print(f"Message: {message}")
        print()

        # Find parent
        parent: str = ""
        for line in lines:
            if line.startswith("parent: "):
                parent = line[len("parent: "):].strip()
                break

        if parent == "NONE":
            break
        current = parent


def parse_commit_files(commit_hash: str) -> dict[str, str]:
    """Parse a commit file and return a dict of filename -> blob_hash."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)
    with open(commit_path, "r") as f:
        lines: list[str] = f.readlines()

    files: dict[str, str] = {}
    in_files: bool = False
    for line in lines:
        if line.strip() == "files:":
            in_files = True
            continue
        if in_files:
            stripped: str = line.strip()
            if stripped:
                parts: list[str] = stripped.split(" ", 1)
                if len(parts) == 2:
                    files[parts[0]] = parts[1]
    return files


def cmd_diff(commit1: str, commit2: str) -> None:
    """Compare two commits."""
    path1: str = os.path.join(COMMITS_DIR, commit1)
    path2: str = os.path.join(COMMITS_DIR, commit2)

    if not os.path.isfile(path1) or not os.path.isfile(path2):
        print("Invalid commit")
        sys.exit(1)

    files1: dict[str, str] = parse_commit_files(commit1)
    files2: dict[str, str] = parse_commit_files(commit2)

    all_files: list[str] = sorted(set(list(files1.keys()) + list(files2.keys())))

    for fname in all_files:
        if fname not in files1:
            print(f"Added: {fname}")
        elif fname not in files2:
            print(f"Removed: {fname}")
        elif files1[fname] != files2[fname]:
            print(f"Modified: {fname}")


def cmd_checkout(commit_hash: str) -> None:
    """Checkout a commit, restoring working directory files."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    files: dict[str, str] = parse_commit_files(commit_hash)

    for fname, blob_hash in files.items():
        blob_path: str = os.path.join(OBJECTS_DIR, blob_hash)
        with open(blob_path, "rb") as bf:
            content: bytes = bf.read()
        with open(fname, "wb") as wf:
            wf.write(content)

    # Update HEAD
    with open(HEAD_FILE, "w") as f:
        f.write(commit_hash)

    # Clear index
    with open(INDEX_FILE, "w") as f:
        pass

    print(f"Checked out {commit_hash}")


def cmd_reset(commit_hash: str) -> None:
    """Reset HEAD to a commit without modifying working directory."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    # Update HEAD
    with open(HEAD_FILE, "w") as f:
        f.write(commit_hash)

    # Clear index
    with open(INDEX_FILE, "w") as f:
        pass

    print(f"Reset to {commit_hash}")


def cmd_rm(filename: str) -> None:
    """Remove a file from the staging index."""
    entries: list[str] = []
    with open(INDEX_FILE, "r") as f:
        for line in f:
            stripped: str = line.strip()
            if stripped:
                entries.append(stripped)

    if filename not in entries:
        print("File not in index")
        sys.exit(1)

    entries.remove(filename)

    with open(INDEX_FILE, "w") as f:
        for entry in entries:
            f.write(entry + "\n")


def cmd_show(commit_hash: str) -> None:
    """Show details of a commit."""
    commit_path: str = os.path.join(COMMITS_DIR, commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        lines: list[str] = f.readlines()

    timestamp: str = ""
    message: str = ""
    for line in lines:
        if line.startswith("timestamp: "):
            timestamp = line[len("timestamp: "):].strip()
        elif line.startswith("message: "):
            message = line[len("message: "):].strip()

    files: dict[str, str] = parse_commit_files(commit_hash)
    sorted_files: list[str] = sorted(files.keys())

    print(f"commit {commit_hash}")
    print(f"Date: {timestamp}")
    print(f"Message: {message}")
    print("Files:")
    for fname in sorted_files:
        print(f"  {fname} {files[fname]}")


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
