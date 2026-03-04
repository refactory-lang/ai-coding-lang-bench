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
    """Initialize a new repository."""
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
        data = f.read()
    h = minihash(data)
    with open(os.path.join(".minigit", "objects", h), "wb") as f:
        f.write(data)
    # Read current index
    with open(".minigit/index", "r") as f:
        lines = f.read().splitlines()
    if filename not in lines:
        lines.append(filename)
        with open(".minigit/index", "w") as f:
            f.write("\n".join(lines) + "\n")


def cmd_commit(message: str) -> None:
    """Create a commit."""
    with open(".minigit/index", "r") as f:
        index_content = f.read().strip()
    if not index_content:
        print("Nothing to commit")
        sys.exit(1)
    filenames = sorted(index_content.splitlines())
    with open(".minigit/HEAD", "r") as f:
        parent = f.read().strip()
    parent_str = parent if parent else "NONE"
    timestamp: int = int(time.time())
    file_entries: list[str] = []
    for fn in filenames:
        with open(fn, "rb") as f:
            data = f.read()
        blob_hash = minihash(data)
        file_entries.append(f"{fn} {blob_hash}")
    commit_text = (
        f"parent: {parent_str}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
    )
    for entry in file_entries:
        commit_text += entry + "\n"
    commit_hash = minihash(commit_text.encode())
    with open(os.path.join(".minigit", "commits", commit_hash), "w") as f:
        f.write(commit_text)
    with open(".minigit/HEAD", "w") as f:
        f.write(commit_hash)
    # Clear index
    with open(".minigit/index", "w") as f:
        pass
    print(f"Committed {commit_hash}")


def cmd_log() -> None:
    """Show commit log."""
    with open(".minigit/HEAD", "r") as f:
        current = f.read().strip()
    if not current:
        print("No commits")
        return
    while current:
        with open(os.path.join(".minigit", "commits", current), "r") as f:
            content = f.read()
        # Parse commit
        timestamp = ""
        message = ""
        parent = ""
        for line in content.splitlines():
            if line.startswith("parent: "):
                parent = line[8:]
            elif line.startswith("timestamp: "):
                timestamp = line[11:]
            elif line.startswith("message: "):
                message = line[9:]
        print(f"commit {current}")
        print(f"Date: {timestamp}")
        print(f"Message: {message}")
        print()
        if parent == "NONE":
            break
        current = parent


def main() -> None:
    """Entry point."""
    if len(sys.argv) < 2:
        print("Usage: minigit <command>")
        sys.exit(1)
    command = sys.argv[1]
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
