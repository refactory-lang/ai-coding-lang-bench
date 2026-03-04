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
        with open(obj_path, "wb") as fw:
            fw.write(content)

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


def cmd_status() -> None:
    """Show staged files."""
    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "r") as f:
        files: list[str] = [line.strip() for line in f if line.strip()]

    print("Staged files:")
    if not files:
        print("(none)")
    else:
        for fname in files:
            print(fname)


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
        parent_hash, timestamp_str, message_str = parse_commit_metadata(commit_path)

        if not first:
            print("")
        first = False

        print(f"commit {current}")
        print(f"Date: {timestamp_str}")
        print(f"Message: {message_str}")

        if parent_hash == "NONE" or not parent_hash:
            break
        current = parent_hash


def parse_commit_files(commit_path: str) -> dict[str, str]:
    """Parse a commit file and return a dict of filename -> blob hash."""
    with open(commit_path, "r") as f:
        lines: list[str] = f.readlines()

    files: dict[str, str] = {}
    in_files: bool = False
    for line in lines:
        stripped: str = line.strip()
        if stripped == "files:":
            in_files = True
            continue
        if in_files and stripped:
            parts: list[str] = stripped.split(" ", 1)
            if len(parts) == 2:
                files[parts[0]] = parts[1]
    return files


def parse_commit_metadata(commit_path: str) -> tuple[str, str, str]:
    """Parse commit file and return (parent, timestamp, message)."""
    with open(commit_path, "r") as f:
        lines: list[str] = f.readlines()

    parent: str = ""
    timestamp: str = ""
    message: str = ""
    for line in lines:
        stripped: str = line.strip()
        if stripped.startswith("parent: "):
            parent = stripped[len("parent: "):]
        elif stripped.startswith("timestamp: "):
            timestamp = stripped[len("timestamp: "):]
        elif stripped.startswith("message: "):
            message = stripped[len("message: "):]
    return parent, timestamp, message


def cmd_diff(commit1: str, commit2: str) -> None:
    """Compare two commits."""
    path1: str = os.path.join(".minigit", "commits", commit1)
    path2: str = os.path.join(".minigit", "commits", commit2)

    if not os.path.isfile(path1) or not os.path.isfile(path2):
        print("Invalid commit")
        sys.exit(1)

    files1: dict[str, str] = parse_commit_files(path1)
    files2: dict[str, str] = parse_commit_files(path2)

    all_files: list[str] = sorted(set(list(files1.keys()) + list(files2.keys())))

    for fname in all_files:
        if fname not in files1:
            print(f"Added: {fname}")
        elif fname not in files2:
            print(f"Removed: {fname}")
        elif files1[fname] != files2[fname]:
            print(f"Modified: {fname}")


def cmd_checkout(commit_hash: str) -> None:
    """Checkout a commit: restore working directory files."""
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    files: dict[str, str] = parse_commit_files(commit_path)

    for fname, blob_hash in files.items():
        blob_path: str = os.path.join(".minigit", "objects", blob_hash)
        with open(blob_path, "rb") as bf:
            content: bytes = bf.read()
        with open(fname, "wb") as wf:
            wf.write(content)

    head_path: str = os.path.join(".minigit", "HEAD")
    with open(head_path, "w") as f:
        f.write(commit_hash)

    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "w") as f:
        pass

    print(f"Checked out {commit_hash}")


def cmd_reset(commit_hash: str) -> None:
    """Reset HEAD to a commit without changing working directory."""
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    head_path: str = os.path.join(".minigit", "HEAD")
    with open(head_path, "w") as f:
        f.write(commit_hash)

    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "w") as f:
        pass

    print(f"Reset to {commit_hash}")


def cmd_rm(filename: str) -> None:
    """Remove a file from the staging index."""
    index_path: str = os.path.join(".minigit", "index")
    with open(index_path, "r") as f:
        files: list[str] = [line.strip() for line in f if line.strip()]

    if filename not in files:
        print("File not in index")
        sys.exit(1)

    files.remove(filename)
    with open(index_path, "w") as f:
        for name in files:
            f.write(name + "\n")


def cmd_show(commit_hash: str) -> None:
    """Show details of a commit."""
    commit_path: str = os.path.join(".minigit", "commits", commit_hash)
    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    parent, timestamp, message = parse_commit_metadata(commit_path)
    files: dict[str, str] = parse_commit_files(commit_path)

    print(f"commit {commit_hash}")
    print(f"Date: {timestamp}")
    print(f"Message: {message}")
    print("Files:")
    for fname in sorted(files.keys()):
        print(f"  {fname} {files[fname]}")


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
