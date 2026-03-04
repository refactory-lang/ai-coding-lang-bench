#!/usr/bin/env python3
"""MiniGit: A minimal version control system."""

import os
import sys
import time


def minihash(data: bytes) -> str:
    """Compute MiniHash (FNV-1a variant, 64-bit, 16-char hex)."""
    h: int = 1469598103934665603
    mod: int = 2 ** 64
    for b in data:
        h ^= b
        h = (h * 1099511628211) % mod
    return format(h, "016x")


def cmd_init() -> None:
    """Initialize a new .minigit repository."""
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

    blob_hash: str = minihash(data)
    blob_path: str = os.path.join(".minigit", "objects", blob_hash)

    with open(blob_path, "wb") as f:
        f.write(data)

    # Read current index
    with open(".minigit/index", "r") as f:
        lines: list[str] = [line.strip() for line in f if line.strip()]

    if filename not in lines:
        lines.append(filename)

    with open(".minigit/index", "w") as f:
        for line in lines:
            f.write(line + "\n")


def cmd_commit(message: str) -> None:
    """Create a commit from staged files."""
    with open(".minigit/index", "r") as f:
        staged: list[str] = [line.strip() for line in f if line.strip()]

    if not staged:
        print("Nothing to commit")
        sys.exit(1)

    with open(".minigit/HEAD", "r") as f:
        parent: str = f.read().strip()

    parent_str: str = parent if parent else "NONE"
    timestamp: int = int(time.time())

    # Build file entries: sorted filenames with their blob hashes
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

    with open(os.path.join(".minigit", "commits", commit_hash), "w") as f:
        f.write(commit_content)

    with open(".minigit/HEAD", "w") as f:
        f.write(commit_hash)

    with open(".minigit/index", "w") as f:
        pass

    print(f"Committed {commit_hash}")


def cmd_status() -> None:
    """Show staged files."""
    with open(".minigit/index", "r") as f:
        staged: list[str] = [line.strip() for line in f if line.strip()]

    print("Staged files:")
    if not staged:
        print("(none)")
    else:
        for fname in staged:
            print(fname)


def cmd_log() -> None:
    """Show commit log, most recent first."""
    with open(".minigit/HEAD", "r") as f:
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

        parent_hash: str = ""
        timestamp_str: str = ""
        message_str: str = ""
        for line in content.splitlines():
            if line.startswith("parent: "):
                parent_hash = line[len("parent: "):]
            elif line.startswith("timestamp: "):
                timestamp_str = line[len("timestamp: "):]
            elif line.startswith("message: "):
                message_str = line[len("message: "):]

        print(f"commit {current}")
        print(f"Date: {timestamp_str}")
        print(f"Message: {message_str}")

        if parent_hash == "NONE":
            break
        current = parent_hash


def parse_commit_files(content: str) -> dict[str, str]:
    """Parse the files section of a commit, returning {filename: blobhash}."""
    files: dict[str, str] = {}
    in_files: bool = False
    for line in content.splitlines():
        if line == "files:":
            in_files = True
            continue
        if in_files and line.strip():
            parts: list[str] = line.strip().split(" ", 1)
            if len(parts) == 2:
                files[parts[0]] = parts[1]
    return files


def cmd_diff(commit1: str, commit2: str) -> None:
    """Compare two commits."""
    path1: str = os.path.join(".minigit", "commits", commit1)
    path2: str = os.path.join(".minigit", "commits", commit2)

    if not os.path.isfile(path1) or not os.path.isfile(path2):
        print("Invalid commit")
        sys.exit(1)

    with open(path1, "r") as f:
        files1: dict[str, str] = parse_commit_files(f.read())
    with open(path2, "r") as f:
        files2: dict[str, str] = parse_commit_files(f.read())

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
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    files: dict[str, str] = parse_commit_files(content)
    for fname, blob_hash in files.items():
        blob_path: str = os.path.join(".minigit", "objects", blob_hash)
        with open(blob_path, "rb") as bf:
            blob_data: bytes = bf.read()
        with open(fname, "wb") as wf:
            wf.write(blob_data)

    with open(".minigit/HEAD", "w") as f:
        f.write(commit_hash)

    with open(".minigit/index", "w") as f:
        pass

    print(f"Checked out {commit_hash}")


def cmd_reset(commit_hash: str) -> None:
    """Reset HEAD to a commit without modifying working directory."""
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(".minigit/HEAD", "w") as f:
        f.write(commit_hash)

    with open(".minigit/index", "w") as f:
        pass

    print(f"Reset to {commit_hash}")


def cmd_rm(filename: str) -> None:
    """Remove a file from the staging index."""
    with open(".minigit/index", "r") as f:
        lines: list[str] = [line.strip() for line in f if line.strip()]

    if filename not in lines:
        print("File not in index")
        sys.exit(1)

    lines.remove(filename)
    with open(".minigit/index", "w") as f:
        for line in lines:
            f.write(line + "\n")


def cmd_show(commit_hash: str) -> None:
    """Show details of a commit."""
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    timestamp_str: str = ""
    message_str: str = ""
    for line in content.splitlines():
        if line.startswith("timestamp: "):
            timestamp_str = line[len("timestamp: "):]
        elif line.startswith("message: "):
            message_str = line[len("message: "):]

    files: dict[str, str] = parse_commit_files(content)

    print(f"commit {commit_hash}")
    print(f"Date: {timestamp_str}")
    print(f"Message: {message_str}")
    print("Files:")
    for fname in sorted(files.keys()):
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
