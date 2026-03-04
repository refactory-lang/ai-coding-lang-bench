"""MiniGit: A minimal version control system."""

import os
import sys
import shutil
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
    base: str = ".minigit"
    if os.path.isdir(base):
        print("Repository already initialized")
        return
    os.makedirs(os.path.join(base, "objects"))
    os.makedirs(os.path.join(base, "commits"))
    with open(os.path.join(base, "index"), "w") as f:
        pass
    with open(os.path.join(base, "HEAD"), "w") as f:
        pass


def cmd_add(filename: str) -> None:
    """Stage a file by computing its hash and storing its blob."""
    if not os.path.isfile(filename):
        print("File not found")
        sys.exit(1)

    with open(filename, "rb") as f:
        content: bytes = f.read()

    h: str = minihash(content)
    obj_path: str = os.path.join(".minigit", "objects", h)
    if not os.path.exists(obj_path):
        shutil.copyfile(filename, obj_path)

    index_path: str = os.path.join(".minigit", "index")
    existing: list[str] = []
    with open(index_path, "r") as f:
        existing = [line.strip() for line in f if line.strip()]

    if filename not in existing:
        existing.append(filename)
        with open(index_path, "w") as f:
            for name in existing:
                f.write(name + "\n")


def cmd_commit(message: str) -> None:
    """Create a commit from the current index."""
    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "r") as f:
        files: list[str] = [line.strip() for line in f if line.strip()]

    if not files:
        print("Nothing to commit")
        sys.exit(1)

    head_path: str = os.path.join(".minigit", "HEAD")
    with open(head_path, "r") as f:
        parent: str = f.read().strip()

    parent_str: str = parent if parent else "NONE"

    # Build file entries: filename + blob hash, sorted
    file_entries: list[str] = []
    for fname in sorted(files):
        with open(fname, "rb") as f:
            content: bytes = f.read()
        h: str = minihash(content)
        file_entries.append(f"{fname} {h}")

    timestamp = int(time.time())

    commit_content: str = (
        f"parent: {parent_str}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
    )
    for entry in file_entries:
        commit_content += entry + "\n"

    commit_hash: str = minihash(commit_content.encode("utf-8"))

    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    with open(commit_path, "w") as f:
        f.write(commit_content)

    with open(head_path, "w") as f:
        f.write(commit_hash)

    # Clear index
    with open(index_path, "w") as f:
        pass

    print(f"Committed {commit_hash}")


def cmd_log() -> None:
    """Show commit log traversing parent chain."""
    head_path: str = os.path.join(".minigit", "HEAD")
    with open(head_path, "r") as f:
        current: str = f.read().strip()

    if not current:
        print("No commits")
        return

    first: bool = True
    while current:
        commit_path: str = os.path.join(".minigit", "commits", current)
        with open(commit_path, "r") as f:
            lines: list[str] = f.readlines()

        parent_hash: str = ""
        timestamp_str: str = ""
        message_str: str = ""
        for line in lines:
            stripped: str = line.strip()
            if stripped.startswith("parent: "):
                parent_hash = stripped[len("parent: "):]
            elif stripped.startswith("timestamp: "):
                timestamp_str = stripped[len("timestamp: "):]
            elif stripped.startswith("message: "):
                message_str = stripped[len("message: "):]

        if not first:
            print("")
        first = False

        print(f"commit {current}")
        print(f"Date: {timestamp_str}")
        print(f"Message: {message_str}")

        if parent_hash == "NONE" or not parent_hash:
            break
        current = parent_hash


def main() -> None:
    """Entry point for minigit."""
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
