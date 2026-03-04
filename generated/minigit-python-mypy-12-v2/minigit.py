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


def parse_commit(content: str) -> tuple[str, str, str, list[tuple[str, str]]]:
    """Parse a commit file and return (parent, timestamp, message, files)."""
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
        staged: list[str] = [line.strip() for line in f if line.strip()]

    if not staged:
        print("Nothing to commit")
        sys.exit(1)

    # Read HEAD
    head_path: str = os.path.join(".minigit", "HEAD")
    with open(head_path, "r") as f:
        parent: str = f.read().strip()

    parent_str: str = parent if parent else "NONE"
    timestamp: int = int(time.time())

    # Build file entries sorted lexicographically
    sorted_files: list[str] = sorted(staged)
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


def cmd_status() -> None:
    """Show staged files."""
    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "r") as f:
        files: list[str] = [line.strip() for line in f if line.strip()]

    print("Staged files:")
    if files:
        for fn in files:
            print(fn)
    else:
        print("(none)")


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

        parent_hash, timestamp_str, message, _ = parse_commit(content)

        print(f"commit {current}")
        print(f"Date: {timestamp_str}")
        print(f"Message: {message}")

        if parent_hash == "NONE":
            break
        current = parent_hash


def cmd_diff(commit1: str, commit2: str) -> None:
    """Compare two commits."""
    commit_path1: str = os.path.join(".minigit", "commits", commit1)
    commit_path2: str = os.path.join(".minigit", "commits", commit2)

    if not os.path.isfile(commit_path1) or not os.path.isfile(commit_path2):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path1, "r") as f:
        content1: str = f.read()
    with open(commit_path2, "r") as f:
        content2: str = f.read()

    _, _, _, files1_list = parse_commit(content1)
    _, _, _, files2_list = parse_commit(content2)

    files1: dict[str, str] = dict(files1_list)
    files2: dict[str, str] = dict(files2_list)

    all_files: list[str] = sorted(set(list(files1.keys()) + list(files2.keys())))

    for fn in all_files:
        if fn not in files1:
            print(f"Added: {fn}")
        elif fn not in files2:
            print(f"Removed: {fn}")
        elif files1[fn] != files2[fn]:
            print(f"Modified: {fn}")


def cmd_checkout(commit_hash: str) -> None:
    """Check out a commit."""
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    _, _, _, files = parse_commit(content)

    for filename, blob_hash in files:
        blob_path: str = os.path.join(".minigit", "objects", blob_hash)
        with open(blob_path, "rb") as f:
            blob_data: bytes = f.read()
        with open(filename, "wb") as f:
            f.write(blob_data)

    # Update HEAD
    head_path: str = os.path.join(".minigit", "HEAD")
    with open(head_path, "w") as f:
        f.write(commit_hash)

    # Clear index
    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "w") as f:
        pass

    print(f"Checked out {commit_hash}")


def cmd_reset(commit_hash: str) -> None:
    """Reset HEAD to a commit without modifying working directory."""
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    # Update HEAD
    head_path: str = os.path.join(".minigit", "HEAD")
    with open(head_path, "w") as f:
        f.write(commit_hash)

    # Clear index
    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "w") as f:
        pass

    print(f"Reset to {commit_hash}")


def cmd_rm(filename: str) -> None:
    """Remove a file from the staging index."""
    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "r") as f:
        lines: list[str] = [line.strip() for line in f if line.strip()]

    if filename not in lines:
        print("File not in index")
        sys.exit(1)

    lines.remove(filename)
    with open(index_path, "w") as f:
        if lines:
            f.write("\n".join(lines) + "\n")


def cmd_show(commit_hash: str) -> None:
    """Show details of a commit."""
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
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
    for filename, blob_hash in sorted(files):
        print(f"  {filename} {blob_hash}")


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
