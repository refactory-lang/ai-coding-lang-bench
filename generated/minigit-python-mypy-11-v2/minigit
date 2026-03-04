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


def read_index() -> list[str]:
    """Read the index file and return list of staged filenames."""
    with open(".minigit/index", "r") as f:
        return [line.strip() for line in f if line.strip()]


def write_index(entries: list[str]) -> None:
    """Write entries to the index file."""
    with open(".minigit/index", "w") as f:
        for entry in entries:
            f.write(entry + "\n")


def read_head() -> str:
    """Read HEAD and return the commit hash (or empty string)."""
    with open(".minigit/HEAD", "r") as f:
        return f.read().strip()


def write_head(commit_hash: str) -> None:
    """Write a commit hash to HEAD."""
    with open(".minigit/HEAD", "w") as f:
        f.write(commit_hash)


def clear_index() -> None:
    """Clear the index file."""
    with open(".minigit/index", "w") as _f:
        pass


def parse_commit(commit_hash: str) -> tuple[str, str, str, list[tuple[str, str]]]:
    """Parse a commit file. Returns (parent, timestamp, message, files)."""
    path: str = os.path.join(".minigit", "commits", commit_hash)
    with open(path, "r") as f:
        content: str = f.read()
    parent: str = ""
    timestamp: str = ""
    message: str = ""
    files: list[tuple[str, str]] = []
    in_files: bool = False
    for line in content.splitlines():
        if in_files:
            parts: list[str] = line.strip().split()
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


def commit_exists(commit_hash: str) -> bool:
    """Check if a commit exists."""
    return os.path.isfile(os.path.join(".minigit", "commits", commit_hash))


def cmd_init() -> None:
    """Initialize a new repository."""
    if os.path.isdir(".minigit"):
        print("Repository already initialized")
        return
    os.makedirs(".minigit/objects", exist_ok=True)
    os.makedirs(".minigit/commits", exist_ok=True)
    with open(".minigit/index", "w") as _f:
        pass
    with open(".minigit/HEAD", "w") as _f:
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
    lines: list[str] = read_index()
    if filename not in lines:
        lines.append(filename)
    write_index(lines)


def cmd_commit(message: str) -> None:
    """Create a commit."""
    staged: list[str] = read_index()
    if not staged:
        print("Nothing to commit")
        sys.exit(1)
    parent: str = read_head()
    parent_str: str = parent if parent else "NONE"
    timestamp: int = int(time.time())
    sorted_files: list[str] = sorted(staged)
    file_lines: list[str] = []
    for fname in sorted_files:
        with open(fname, "rb") as f:
            data: bytes = f.read()
        h: str = minihash(data)
        file_lines.append(f"{fname} {h}")
    commit_content: str = (
        f"parent: {parent_str}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
    )
    for fl in file_lines:
        commit_content += fl + "\n"
    commit_hash: str = minihash(commit_content.encode())
    with open(os.path.join(".minigit", "commits", commit_hash), "w") as f:
        f.write(commit_content)
    write_head(commit_hash)
    clear_index()
    print(f"Committed {commit_hash}")


def cmd_status() -> None:
    """Show staged files."""
    staged: list[str] = read_index()
    print("Staged files:")
    if staged:
        for fname in staged:
            print(fname)
    else:
        print("(none)")


def cmd_log() -> None:
    """Show commit log."""
    head: str = read_head()
    if not head:
        print("No commits")
        return
    current: str = head
    while current and current != "NONE":
        parent, timestamp, message, _files = parse_commit(current)
        print(f"commit {current}")
        print(f"Date: {timestamp}")
        print(f"Message: {message}")
        print()
        current = parent


def cmd_diff(commit1: str, commit2: str) -> None:
    """Compare two commits."""
    if not commit_exists(commit1) or not commit_exists(commit2):
        print("Invalid commit")
        sys.exit(1)
    _p1, _t1, _m1, files1 = parse_commit(commit1)
    _p2, _t2, _m2, files2 = parse_commit(commit2)
    map1: dict[str, str] = {name: blob for name, blob in files1}
    map2: dict[str, str] = {name: blob for name, blob in files2}
    all_files: list[str] = sorted(set(list(map1.keys()) + list(map2.keys())))
    for fname in all_files:
        if fname not in map1:
            print(f"Added: {fname}")
        elif fname not in map2:
            print(f"Removed: {fname}")
        elif map1[fname] != map2[fname]:
            print(f"Modified: {fname}")


def cmd_checkout(commit_hash: str) -> None:
    """Checkout a commit, restoring working directory files."""
    if not commit_exists(commit_hash):
        print("Invalid commit")
        sys.exit(1)
    _parent, _timestamp, _message, files = parse_commit(commit_hash)
    for fname, blob_hash in files:
        blob_path: str = os.path.join(".minigit", "objects", blob_hash)
        with open(blob_path, "rb") as f:
            content: bytes = f.read()
        with open(fname, "wb") as f:
            f.write(content)
    write_head(commit_hash)
    clear_index()
    print(f"Checked out {commit_hash}")


def cmd_reset(commit_hash: str) -> None:
    """Reset HEAD to a commit without modifying working directory."""
    if not commit_exists(commit_hash):
        print("Invalid commit")
        sys.exit(1)
    write_head(commit_hash)
    clear_index()
    print(f"Reset to {commit_hash}")


def cmd_rm(filename: str) -> None:
    """Remove a file from the staging index."""
    entries: list[str] = read_index()
    if filename not in entries:
        print("File not in index")
        sys.exit(1)
    entries.remove(filename)
    write_index(entries)


def cmd_show(commit_hash: str) -> None:
    """Show details of a commit."""
    if not commit_exists(commit_hash):
        print("Invalid commit")
        sys.exit(1)
    _parent, timestamp, message, files = parse_commit(commit_hash)
    print(f"commit {commit_hash}")
    print(f"Date: {timestamp}")
    print(f"Message: {message}")
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
