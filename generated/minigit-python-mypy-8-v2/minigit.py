#!/usr/bin/env python3
"""MiniGit: a minimal version control system."""

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
    """Initialize a .minigit repository."""
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
    with open(".minigit/index", "r") as f:
        lines: list[str] = [line.strip() for line in f if line.strip()]
    if filename not in lines:
        lines.append(filename)
        with open(".minigit/index", "w") as f:
            f.write("\n".join(lines) + "\n")


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
    ts: int = int(time.time())
    sorted_files: list[str] = sorted(staged)
    file_lines: list[str] = []
    for fname in sorted_files:
        with open(fname, "rb") as f:
            data: bytes = f.read()
        h: str = minihash(data)
        file_lines.append(f"{fname} {h}")
    content: str = (
        f"parent: {parent_str}\n"
        f"timestamp: {ts}\n"
        f"message: {message}\n"
        f"files:\n"
        + "\n".join(file_lines) + "\n"
    )
    commit_hash: str = minihash(content.encode("utf-8"))
    with open(os.path.join(".minigit", "commits", commit_hash), "w") as f:
        f.write(content)
    with open(".minigit/HEAD", "w") as f:
        f.write(commit_hash)
    with open(".minigit/index", "w") as f:
        pass
    print(f"Committed {commit_hash}")


def read_commit(commit_hash: str) -> dict[str, str] :
    """Read a commit file and return its fields."""
    path: str = os.path.join(".minigit", "commits", commit_hash)
    with open(path, "r") as f:
        text: str = f.read()
    result: dict[str, str] = {}
    for line in text.split("\n"):
        if line.startswith("parent: "):
            result["parent"] = line[len("parent: "):]
        elif line.startswith("timestamp: "):
            result["timestamp"] = line[len("timestamp: "):]
        elif line.startswith("message: "):
            result["message"] = line[len("message: "):]
    return result


def read_commit_files(commit_hash: str) -> list[tuple[str, str]]:
    """Read the files section of a commit. Returns list of (filename, blobhash)."""
    path: str = os.path.join(".minigit", "commits", commit_hash)
    with open(path, "r") as f:
        text: str = f.read()
    files: list[tuple[str, str]] = []
    in_files: bool = False
    for line in text.split("\n"):
        if line == "files:":
            in_files = True
            continue
        if in_files and line.strip():
            parts: list[str] = line.split()
            if len(parts) == 2:
                files.append((parts[0], parts[1]))
    return files


def commit_exists(commit_hash: str) -> bool:
    """Check if a commit exists."""
    return os.path.isfile(os.path.join(".minigit", "commits", commit_hash))


def cmd_status() -> None:
    """Show staged files."""
    with open(".minigit/index", "r") as f:
        staged: list[str] = [line.strip() for line in f if line.strip()]
    print("Staged files:")
    if not staged:
        print("(none)")
    else:
        for s in staged:
            print(s)


def cmd_log() -> None:
    """Show commit log traversing parent chain."""
    with open(".minigit/HEAD", "r") as f:
        current: str = f.read().strip()
    if not current:
        print("No commits")
        return
    first: bool = True
    while current and current != "NONE":
        if not first:
            print()
        first = False
        info: dict[str, str] = read_commit(current)
        print(f"commit {current}")
        print(f"Date: {info['timestamp']}")
        print(f"Message: {info['message']}")
        current = info.get("parent", "NONE")
        if current == "NONE":
            break


def cmd_diff(commit1: str, commit2: str) -> None:
    """Compare two commits."""
    if not commit_exists(commit1) or not commit_exists(commit2):
        print("Invalid commit")
        sys.exit(1)
    files1: dict[str, str] = dict(read_commit_files(commit1))
    files2: dict[str, str] = dict(read_commit_files(commit2))
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
    if not commit_exists(commit_hash):
        print("Invalid commit")
        sys.exit(1)
    files: list[tuple[str, str]] = read_commit_files(commit_hash)
    for fname, blob_hash in files:
        blob_path: str = os.path.join(".minigit", "objects", blob_hash)
        with open(blob_path, "rb") as f:
            content: bytes = f.read()
        with open(fname, "wb") as f:
            f.write(content)
    with open(".minigit/HEAD", "w") as f:
        f.write(commit_hash)
    with open(".minigit/index", "w") as f:
        pass
    print(f"Checked out {commit_hash}")


def cmd_reset(commit_hash: str) -> None:
    """Reset HEAD to a commit without modifying working directory."""
    if not commit_exists(commit_hash):
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
        if lines:
            f.write("\n".join(lines) + "\n")


def cmd_show(commit_hash: str) -> None:
    """Show details of a commit."""
    if not commit_exists(commit_hash):
        print("Invalid commit")
        sys.exit(1)
    info: dict[str, str] = read_commit(commit_hash)
    files: list[tuple[str, str]] = read_commit_files(commit_hash)
    print(f"commit {commit_hash}")
    print(f"Date: {info['timestamp']}")
    print(f"Message: {info['message']}")
    print("Files:")
    for fname, blob_hash in sorted(files):
        print(f"  {fname} {blob_hash}")


def main() -> None:
    """Entry point."""
    if len(sys.argv) < 2:
        print("Usage: minigit <command>")
        sys.exit(1)
    cmd: str = sys.argv[1]
    if cmd == "init":
        cmd_init()
    elif cmd == "add":
        if len(sys.argv) < 3:
            print("Usage: minigit add <file>")
            sys.exit(1)
        cmd_add(sys.argv[2])
    elif cmd == "commit":
        if len(sys.argv) < 4 or sys.argv[2] != "-m":
            print('Usage: minigit commit -m "<message>"')
            sys.exit(1)
        cmd_commit(sys.argv[3])
    elif cmd == "status":
        cmd_status()
    elif cmd == "log":
        cmd_log()
    elif cmd == "diff":
        if len(sys.argv) < 4:
            print("Usage: minigit diff <commit1> <commit2>")
            sys.exit(1)
        cmd_diff(sys.argv[2], sys.argv[3])
    elif cmd == "checkout":
        if len(sys.argv) < 3:
            print("Usage: minigit checkout <commit_hash>")
            sys.exit(1)
        cmd_checkout(sys.argv[2])
    elif cmd == "reset":
        if len(sys.argv) < 3:
            print("Usage: minigit reset <commit_hash>")
            sys.exit(1)
        cmd_reset(sys.argv[2])
    elif cmd == "rm":
        if len(sys.argv) < 3:
            print("Usage: minigit rm <file>")
            sys.exit(1)
        cmd_rm(sys.argv[2])
    elif cmd == "show":
        if len(sys.argv) < 3:
            print("Usage: minigit show <commit_hash>")
            sys.exit(1)
        cmd_show(sys.argv[2])
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
