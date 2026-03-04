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


def get_minigit_dir() -> str:
    """Return the path to the .minigit directory."""
    return os.path.join(os.getcwd(), ".minigit")


def cmd_init() -> None:
    """Initialize a new repository."""
    mgdir: str = get_minigit_dir()
    if os.path.isdir(mgdir):
        print("Repository already initialized")
        return
    os.makedirs(os.path.join(mgdir, "objects"))
    os.makedirs(os.path.join(mgdir, "commits"))
    with open(os.path.join(mgdir, "index"), "w") as f:
        f.write("")
    with open(os.path.join(mgdir, "HEAD"), "w") as f:
        f.write("")


def cmd_add(filename: str) -> None:
    """Stage a file."""
    if not os.path.isfile(filename):
        print("File not found")
        sys.exit(1)

    with open(filename, "rb") as f:
        content: bytes = f.read()

    blob_hash: str = minihash(content)
    blob_path: str = os.path.join(get_minigit_dir(), "objects", blob_hash)

    with open(blob_path, "wb") as f:
        f.write(content)

    index_path: str = os.path.join(get_minigit_dir(), "index")
    entries: list[str] = []
    with open(index_path, "r") as f:
        text: str = f.read()
        if text.strip():
            entries = text.strip().split("\n")

    if filename not in entries:
        entries.append(filename)

    with open(index_path, "w") as f:
        f.write("\n".join(entries) + "\n")


def cmd_commit(message: str) -> None:
    """Create a commit."""
    mgdir: str = get_minigit_dir()
    index_path: str = os.path.join(mgdir, "index")

    with open(index_path, "r") as f:
        text: str = f.read().strip()

    if not text:
        print("Nothing to commit")
        sys.exit(1)

    filenames: list[str] = sorted(text.split("\n"))

    head_path: str = os.path.join(mgdir, "HEAD")
    with open(head_path, "r") as f:
        parent: str = f.read().strip()

    parent_str: str = parent if parent else "NONE"

    timestamp: int = int(time.time())

    file_lines: list[str] = []
    for fn in filenames:
        blob_content: bytes
        with open(fn, "rb") as f:
            blob_content = f.read()
        blob_hash: str = minihash(blob_content)
        # Also ensure the blob is stored
        blob_path: str = os.path.join(mgdir, "objects", blob_hash)
        with open(blob_path, "wb") as f:
            f.write(blob_content)
        file_lines.append(f"{fn} {blob_hash}")

    commit_content: str = (
        f"parent: {parent_str}\n"
        f"timestamp: {timestamp}\n"
        f"message: {message}\n"
        f"files:\n"
        + "\n".join(file_lines)
        + "\n"
    )

    commit_hash: str = minihash(commit_content.encode("utf-8"))

    with open(os.path.join(mgdir, "commits", commit_hash), "w") as f:
        f.write(commit_content)

    with open(head_path, "w") as f:
        f.write(commit_hash)

    with open(index_path, "w") as f:
        f.write("")

    print(f"Committed {commit_hash}")


def cmd_status() -> None:
    """Show staged files."""
    index_path: str = os.path.join(get_minigit_dir(), "index")
    with open(index_path, "r") as f:
        text: str = f.read().strip()
    print("Staged files:")
    if text:
        for fn in text.split("\n"):
            print(fn)
    else:
        print("(none)")


def parse_commit_files(content: str) -> dict[str, str]:
    """Parse files section from commit content into {filename: hash} dict."""
    files: dict[str, str] = {}
    in_files: bool = False
    for line in content.split("\n"):
        if line == "files:":
            in_files = True
            continue
        if in_files and line.strip():
            parts: list[str] = line.split(" ", 1)
            if len(parts) == 2:
                files[parts[0]] = parts[1]
    return files


def cmd_log() -> None:
    """Show commit log."""
    mgdir: str = get_minigit_dir()
    head_path: str = os.path.join(mgdir, "HEAD")

    with open(head_path, "r") as f:
        current: str = f.read().strip()

    if not current:
        print("No commits")
        return

    first: bool = True
    while current:
        commit_path: str = os.path.join(mgdir, "commits", current)
        with open(commit_path, "r") as f:
            content: str = f.read()

        parent: str = ""
        timestamp: str = ""
        message: str = ""
        for line in content.split("\n"):
            if line.startswith("parent: "):
                parent = line[len("parent: "):]
            elif line.startswith("timestamp: "):
                timestamp = line[len("timestamp: "):]
            elif line.startswith("message: "):
                message = line[len("message: "):]

        if not first:
            print()
        first = False

        print(f"commit {current}")
        print(f"Date: {timestamp}")
        print(f"Message: {message}")

        if parent == "NONE":
            break
        current = parent


def cmd_diff(commit1: str, commit2: str) -> None:
    """Compare two commits."""
    mgdir: str = get_minigit_dir()
    path1: str = os.path.join(mgdir, "commits", commit1)
    path2: str = os.path.join(mgdir, "commits", commit2)

    if not os.path.isfile(path1) or not os.path.isfile(path2):
        print("Invalid commit")
        sys.exit(1)

    with open(path1, "r") as f:
        files1: dict[str, str] = parse_commit_files(f.read())
    with open(path2, "r") as f:
        files2: dict[str, str] = parse_commit_files(f.read())

    all_files: list[str] = sorted(set(list(files1.keys()) + list(files2.keys())))
    for fn in all_files:
        if fn not in files1:
            print(f"Added: {fn}")
        elif fn not in files2:
            print(f"Removed: {fn}")
        elif files1[fn] != files2[fn]:
            print(f"Modified: {fn}")


def cmd_checkout(commit_hash: str) -> None:
    """Checkout a commit: restore files and update HEAD."""
    mgdir: str = get_minigit_dir()
    commit_path: str = os.path.join(mgdir, "commits", commit_hash)

    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    files: dict[str, str] = parse_commit_files(content)
    for fn, blob_hash in files.items():
        blob_path: str = os.path.join(mgdir, "objects", blob_hash)
        with open(blob_path, "rb") as bf:
            blob_content: bytes = bf.read()
        with open(fn, "wb") as wf:
            wf.write(blob_content)

    with open(os.path.join(mgdir, "HEAD"), "w") as f:
        f.write(commit_hash)

    with open(os.path.join(mgdir, "index"), "w") as f:
        f.write("")

    print(f"Checked out {commit_hash}")


def cmd_reset(commit_hash: str) -> None:
    """Reset HEAD to a commit without changing working directory."""
    mgdir: str = get_minigit_dir()
    commit_path: str = os.path.join(mgdir, "commits", commit_hash)

    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(os.path.join(mgdir, "HEAD"), "w") as f:
        f.write(commit_hash)

    with open(os.path.join(mgdir, "index"), "w") as f:
        f.write("")

    print(f"Reset to {commit_hash}")


def cmd_rm(filename: str) -> None:
    """Remove a file from the staging index."""
    index_path: str = os.path.join(get_minigit_dir(), "index")
    with open(index_path, "r") as f:
        text: str = f.read().strip()

    entries: list[str] = text.split("\n") if text else []

    if filename not in entries:
        print("File not in index")
        sys.exit(1)

    entries.remove(filename)

    with open(index_path, "w") as f:
        if entries:
            f.write("\n".join(entries) + "\n")
        else:
            f.write("")


def cmd_show(commit_hash: str) -> None:
    """Show commit details."""
    mgdir: str = get_minigit_dir()
    commit_path: str = os.path.join(mgdir, "commits", commit_hash)

    if not os.path.isfile(commit_path):
        print("Invalid commit")
        sys.exit(1)

    with open(commit_path, "r") as f:
        content: str = f.read()

    timestamp: str = ""
    message: str = ""
    for line in content.split("\n"):
        if line.startswith("timestamp: "):
            timestamp = line[len("timestamp: "):]
        elif line.startswith("message: "):
            message = line[len("message: "):]

    files: dict[str, str] = parse_commit_files(content)

    print(f"commit {commit_hash}")
    print(f"Date: {timestamp}")
    print(f"Message: {message}")
    print("Files:")
    for fn in sorted(files.keys()):
        print(f"  {fn} {files[fn]}")


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
            print('Usage: minigit commit -m "<message>"')
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
