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
    """Initialize a new minigit repository."""
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
        for line in lines:
            f.write(line + "\n")


def cmd_commit(message: str) -> None:
    """Create a commit."""
    with open(".minigit/index", "r") as f:
        staged: list[str] = [line.strip() for line in f if line.strip()]
    if not staged:
        print("Nothing to commit")
        sys.exit(1)
    # Read HEAD
    with open(".minigit/HEAD", "r") as f:
        parent: str = f.read().strip()
    parent_str: str = parent if parent else "NONE"
    # Get timestamp
    timestamp: int = int(time.time())
    # Build file entries sorted
    file_entries: list[str] = []
    for fn in sorted(staged):
        with open(fn, "rb") as f:
            data: bytes = f.read()
        h: str = minihash(data)
        # Ensure blob exists
        obj_path: str = os.path.join(".minigit", "objects", h)
        with open(obj_path, "wb") as f:
            f.write(data)
        file_entries.append(f"{fn} {h}")
    # Build commit content
    commit_content: str = f"parent: {parent_str}\ntimestamp: {timestamp}\nmessage: {message}\nfiles:\n"
    for entry in file_entries:
        commit_content += entry + "\n"
    commit_hash: str = minihash(commit_content.encode())
    # Write commit
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    with open(commit_path, "w") as f:
        f.write(commit_content)
    # Update HEAD
    with open(".minigit/HEAD", "w") as f:
        f.write(commit_hash)
    # Clear index
    with open(".minigit/index", "w") as f:
        pass
    print(f"Committed {commit_hash}")


def cmd_log() -> None:
    """Show commit log."""
    with open(".minigit/HEAD", "r") as f:
        current: str = f.read().strip()
    if not current:
        print("No commits")
        return
    while current:
        commit_path: str = os.path.join(".minigit", "commits", current)
        with open(commit_path, "r") as f:
            content: str = f.read()
        # Parse
        timestamp: str = ""
        message: str = ""
        parent: str = ""
        for line in content.split("\n"):
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
