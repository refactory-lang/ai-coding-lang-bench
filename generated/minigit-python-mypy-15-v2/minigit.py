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
    """Read HEAD and return commit hash or empty string."""
    with open(".minigit/HEAD", "r") as f:
        return f.read().strip()


def write_head(commit_hash: str) -> None:
    """Write a commit hash to HEAD."""
    with open(".minigit/HEAD", "w") as f:
        f.write(commit_hash)


def clear_index() -> None:
    """Clear the index file."""
    with open(".minigit/index", "w") as f:
        pass


def parse_commit(content: str) -> tuple[str, str, str, list[tuple[str, str]]]:
    """Parse commit content, return (parent, timestamp, message, files)."""
    parent: str = ""
    timestamp: str = ""
    message: str = ""
    files: list[tuple[str, str]] = []
    in_files: bool = False
    for line in content.split("\n"):
        if in_files:
            parts: list[str] = line.strip().split(" ", 1)
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
    lines: list[str] = read_index()
    if filename not in lines:
        lines.append(filename)
    write_index(lines)


def cmd_commit(message: str) -> None:
    """Create a commit from staged files."""
    staged: list[str] = read_index()
    if not staged:
        print("Nothing to commit")
        sys.exit(1)
    parent: str = read_head()
    parent_str: str = parent if parent else "NONE"
    timestamp: int = int(time.time())
    sorted_files: list[str] = sorted(staged)
    file_entries: list[str] = []
    for fn in sorted_files:
        with open(fn, "rb") as f:
            data: bytes = f.read()
        blob_hash: str = minihash(data)
        file_entries.append(f"{fn} {blob_hash}")
    commit_content: str = (
        f"parent: {parent_str}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
    )
    for entry in file_entries:
        commit_content += entry + "\n"
    commit_hash: str = minihash(commit_content.encode())
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    with open(commit_path, "w") as f:
        f.write(commit_content)
    write_head(commit_hash)
    clear_index()
    print(f"Committed {commit_hash}")


def cmd_status() -> None:
    """Show staged files."""
    staged: list[str] = read_index()
    print("Staged files:")
    if not staged:
        print("(none)")
    else:
        for fn in staged:
            print(fn)


def cmd_log() -> None:
    """Show commit log traversing parent chain."""
    current: str = read_head()
    if not current:
        print("No commits")
        return
    while current:
        commit_path: str = os.path.join(".minigit", "commits", current)
        with open(commit_path, "r") as f:
            content: str = f.read()
        parent_hash, timestamp_str, message_str, _ = parse_commit(content)
        print(f"commit {current}")
        print(f"Date: {timestamp_str}")
        print(f"Message: {message_str}")
        print()
        if parent_hash == "NONE" or not parent_hash:
            break
        current = parent_hash


def cmd_diff(commit1: str, commit2: str) -> None:
    """Compare two commits."""
    if not commit_exists(commit1) or not commit_exists(commit2):
        print("Invalid commit")
        sys.exit(1)
    with open(os.path.join(".minigit", "commits", commit1), "r") as f:
        content1: str = f.read()
    with open(os.path.join(".minigit", "commits", commit2), "r") as f:
        content2: str = f.read()
    _, _, _, files1 = parse_commit(content1)
    _, _, _, files2 = parse_commit(content2)
    map1: dict[str, str] = {name: blob for name, blob in files1}
    map2: dict[str, str] = {name: blob for name, blob in files2}
    all_files: list[str] = sorted(set(list(map1.keys()) + list(map2.keys())))
    for fn in all_files:
        if fn not in map1 and fn in map2:
            print(f"Added: {fn}")
        elif fn in map1 and fn not in map2:
            print(f"Removed: {fn}")
        elif fn in map1 and fn in map2 and map1[fn] != map2[fn]:
            print(f"Modified: {fn}")


def cmd_checkout(commit_hash: str) -> None:
    """Checkout a commit, restoring working directory files."""
    if not commit_exists(commit_hash):
        print("Invalid commit")
        sys.exit(1)
    with open(os.path.join(".minigit", "commits", commit_hash), "r") as f:
        content: str = f.read()
    _, _, _, files = parse_commit(content)
    for filename, blob_hash in files:
        blob_path: str = os.path.join(".minigit", "objects", blob_hash)
        with open(blob_path, "rb") as f:
            data: bytes = f.read()
        with open(filename, "wb") as f:
            f.write(data)
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
    staged: list[str] = read_index()
    if filename not in staged:
        print("File not in index")
        sys.exit(1)
    staged.remove(filename)
    if staged:
        write_index(staged)
    else:
        clear_index()


def cmd_show(commit_hash: str) -> None:
    """Show details of a commit."""
    if not commit_exists(commit_hash):
        print("Invalid commit")
        sys.exit(1)
    with open(os.path.join(".minigit", "commits", commit_hash), "r") as f:
        content: str = f.read()
    _, timestamp_str, message_str, files = parse_commit(content)
    print(f"commit {commit_hash}")
    print(f"Date: {timestamp_str}")
    print(f"Message: {message_str}")
    print("Files:")
    for filename, blob_hash in sorted(files, key=lambda x: x[0]):
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
