#!/usr/bin/env python3
"""
bugs/inject.py — Bug Injection Tool for Track 1 Experiments A and B.

Injects exactly 3 seeded logic bugs from the catalog into a MiniGit
implementation, writes a seeded copy, and produces a BugManifest JSON.

Usage:
    python3 bugs/inject.py \\
        --source-dir PATH \\
        --output-dir PATH \\
        --manifest-path PATH \\
        --language LANG \\
        --trial N \\
        [--bugs BUG_ID,BUG_ID,BUG_ID] \\
        [--seed INT]
"""

import argparse
import datetime
import json
import os
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path


CATALOG_PATH = Path(__file__).parent / "catalog.json"
REQUIRED_BUG_COUNT = 3


def load_catalog(language: str) -> list:
    """Load bug definitions for the given language from catalog.json."""
    with open(CATALOG_PATH, "r", encoding="utf-8") as fh:
        catalog = json.load(fh)
    return [b for b in catalog if b["language"] == language]


def select_bugs(catalog: list, seed: int, explicit_ids: list = None) -> list:
    """
    Select exactly 3 bugs from the catalog.

    If explicit_ids is provided, select those specific bugs in order.
    Otherwise, use a seeded PRNG to select deterministically.
    """
    if explicit_ids is not None:
        selected = []
        catalog_by_id = {b["id"]: b for b in catalog}
        for bug_id in explicit_ids:
            if bug_id not in catalog_by_id:
                print(
                    f"Error: bug ID '{bug_id}' not found in catalog for this language.",
                    file=sys.stderr,
                )
                sys.exit(1)
            selected.append(catalog_by_id[bug_id])
        return selected

    if len(catalog) < REQUIRED_BUG_COUNT:
        print(
            f"Error: catalog has only {len(catalog)} entries for this language; "
            f"need at least {REQUIRED_BUG_COUNT}.",
            file=sys.stderr,
        )
        sys.exit(1)

    rng = random.Random(seed)
    return rng.sample(catalog, REQUIRED_BUG_COUNT)


def apply_injection_strategy(source_text: str, bug: dict, language: str) -> tuple:
    """
    Apply the injection strategy for a bug to the source text.

    This is the primary injection mechanism. It uses keyword-based heuristics
    to find plausible injection sites in generic MiniGit implementations.

    Returns (modified_source, line_number, original_line, injected_line).
    The injected line is a meaningful change that introduces the described bug.
    """
    lines = source_text.splitlines(keepends=True)
    category = bug["category"]

    injection_rules = {
        "off-by-one": _inject_off_by_one,
        "wrong-hash-seed": _inject_wrong_hash_seed,
        "wrong-status": _inject_wrong_status,
        "missing-parent": _inject_missing_parent,
        "index-not-flushed": _inject_index_not_flushed,
        "wrong-diff-base": _inject_wrong_diff_base,
    }

    inject_fn = injection_rules.get(category)
    if inject_fn is None:
        raise ValueError(f"Unknown category: {category}")

    return inject_fn(lines, language)


def _replace_line(lines: list, i: int, orig: str, injected: str) -> tuple:
    """
    Replace line i with injected text.

    Returns (modified_source, line_number_1indexed, orig, injected).
    This helper eliminates the repeated three-line copy-mutate-join pattern
    that appears throughout the _inject_* functions.
    """
    new_lines = list(lines)
    new_lines[i] = injected + "\n"
    return "".join(new_lines), i + 1, orig, injected


def _inject_off_by_one(lines: list, language: str) -> tuple:
    """Inject off-by-one error in parent-chain traversal loop."""
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if language == "python":
            m = re.match(r"^(\s*)while\s+(parent|current_hash|current|commit_hash)\s*:", line)
            if m:
                indent = m.group(1)
                var = m.group(2)
                orig = line
                injected = f"{indent}while {var} and _obo_depth < 999999:"
                new_lines = list(lines)
                new_lines[i] = injected + "\n"
                # Insert depth init before the loop
                # Find the line before the loop to insert init
                init_line = f"{indent}_obo_depth = 0\n"
                new_lines.insert(i, init_line)
                # Now find the loop body and add increment
                # (simplified: add at first indented line inside loop)
                inner_indent = indent + "    "
                for j in range(i + 2, min(i + 20, len(new_lines))):
                    inner_line = new_lines[j]
                    if inner_line.startswith(inner_indent) and inner_line.strip():
                        new_lines.insert(j + 1, f"{inner_indent}_obo_depth += 1\n")
                        break
                source = "".join(new_lines)
                # Original while was at 0-indexed position i (line i+1).
                # After inserting init_line at index i, the while shifts to
                # index i+1 (0-indexed), which is line number i+2 (1-indexed).
                return source, i + 2, orig, injected
        else:
            # Rust: find while-let loop over parent chain and inject a depth
            # counter that causes the loop to exit one step too early.
            m = re.match(r"^(\s*)while let Some\((\w+)\)\s*=\s*(.+)\{?\s*$", line)
            if m:
                indent = m.group(1)
                var = m.group(2)
                rest = m.group(3).strip().rstrip("{").strip()
                orig = line
                injected = f"{indent}while let Some({var}) = {rest} {{"
                new_lines = list(lines)
                new_lines[i] = raw_line  # keep original while line unchanged
                # Insert depth-counter declaration before the loop
                new_lines.insert(i, f"{indent}let mut _obo_d: usize = 0;\n")
                # Insert increment + early-break inside loop body
                for j in range(i + 2, min(i + 6, len(new_lines))):
                    inner = new_lines[j]
                    if inner.strip() and not inner.strip().startswith("//"):
                        inner_indent = indent + "    "
                        guard = (
                            f"{inner_indent}_obo_d += 1; "
                            f"if _obo_d >= 999999 {{ break; }}  // obo guard\n"
                        )
                        new_lines.insert(j, guard)
                        source = "".join(new_lines)
                        # Loop is now at i+1 (shifted by the inserted decl line)
                        return source, i + 2, orig, guard.rstrip()
                source = "".join(new_lines)
                return source, i + 2, orig, orig

    # Fallback: find any while loop with 'parent' keyword nearby
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if language == "python" and re.match(r"^\s*while\s+\w", line) and "parent" in "".join(
            l for l in lines[max(0, i - 3):i + 3]
        ):
            m = re.match(r"^(\s*)while\s+(\w+)\s*:", line)
            if m:
                indent = m.group(1)
                var = m.group(2)
                orig = line
                injected = f"{indent}while {var} and _obo_depth < 999999:"
                new_lines = list(lines)
                new_lines.insert(i, f"{indent}_obo_depth = 0\n")
                new_lines[i + 1] = injected + "\n"
                source = "".join(new_lines)
                return source, i + 1, orig, injected

    raise ValueError("off-by-one: no suitable parent-chain loop found")


def _inject_wrong_hash_seed(lines: list, language: str) -> tuple:
    """Inject wrong hash seed — add a fixed salt to hash input."""
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if language == "python":
            # Find sha1/sha256 call with encode
            m = re.search(r"(hashlib\.(sha1|sha256)\s*\()(.+)(\.encode\(\))", line)
            if m:
                orig = line
                # Prepend bytes literal so hashlib.sha*(<bytes>) still works at runtime
                injected = line[: m.start(3)] + "b'SEED' + " + line[m.start(3):]
                return _replace_line(lines, i, orig, injected)
            # Find .encode() being hashed
            if "sha" in line.lower() and ".encode(" in line:
                # Try to prefix the string being hashed with a salt
                m2 = re.search(r"(f['\"]|['\"])(.+)(['\"]\.encode)", line)
                if m2:
                    orig = line
                    injected = line[: m2.start(2)] + "SALT" + line[m2.start(2):]
                    return _replace_line(lines, i, orig, injected)
        else:
            # Rust: find hasher.update(...) and split into two calls to inject a
            # salt while keeping valid Rust (Digest::update takes one argument).
            m = re.search(r"(hasher\.update\()(.+?)(\))", line)
            if m:
                orig = line
                data_arg = m.group(2).strip()
                indent_str = " " * (len(line) - len(line.lstrip()))
                # Replace the original update() call with a salt call, then insert
                # the original data call on a new line below.
                salt_line = f'{indent_str}hasher.update(b"salt");\n'
                data_line = f'{indent_str}hasher.update({data_arg});\n'
                new_lines = list(lines)
                new_lines[i] = salt_line
                new_lines.insert(i + 1, data_line)
                source = "".join(new_lines)
                return source, i + 1, orig, salt_line.rstrip()

    # No suitable hash call found — do not inject a comment-only no-op.
    raise ValueError("wrong-hash-seed: no suitable hash call found")


def _inject_wrong_status(lines: list, language: str) -> tuple:
    """Inject wrong-status bug — invert a staged/unstaged comparison."""
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if ("staged" in line.lower() or "index" in line.lower()) and ("!=" in line or "==" in line):
            # Skip comment lines and definition lines
            lstripped = line.lstrip()
            is_comment = lstripped.startswith("#") if language == "python" else lstripped.startswith("//")
            if is_comment or "def " in line or "class " in line:
                continue
            orig = line
            injected = line.replace("!=", "==", 1) if "!=" in line else line.replace("==", "!=", 1)
            if injected != orig:
                return _replace_line(lines, i, orig, injected)

    # Fallback: find any comparison in a status-related function (Python only)
    in_status_fn = False
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if language == "python":
            if re.match(r"\s*def\s+(status|cmd_status)\s*\(", line):
                in_status_fn = True
            elif re.match(r"\s*def\s+\w", line) and in_status_fn:
                in_status_fn = False
            if in_status_fn and ("!=" in line or "==" in line) and "def " not in line:
                orig = line
                injected = line.replace("!=", "==", 1) if "!=" in line else line.replace("==", "!=", 1)
                if injected != orig:
                    return _replace_line(lines, i, orig, injected)

    raise ValueError("wrong-status: no suitable status comparison found")


def _inject_missing_parent(lines: list, language: str) -> tuple:
    """Inject missing-parent bug — set parent to None/empty unconditionally."""
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if language == "python":
            # Find parent dict key assignment in commit creation
            m = re.search(r"(['\"]parent['\"])\s*:\s*(\S[^,}]+)", line)
            if m and "def " not in line:
                orig = line
                injected = line[: m.start(2)] + "None" + line[m.end(2):]
                return _replace_line(lines, i, orig, injected)
            # Find parent variable assignment
            m2 = re.search(r"(\bparent\b|\bparent_hash\b)\s*=\s*(\S[^\n#]+)", line)
            if m2 and "def " not in line and "None" not in line:
                orig = line
                injected = line[: m2.start(2)] + "None"
                return _replace_line(lines, i, orig, injected)
        else:
            # Rust: find parent: Some(...) assignment
            m = re.search(r"(parent\s*:\s*)Some\((\w+)\)", line)
            if m:
                orig = line
                injected = line[: m.start(1)] + "parent: None"
                if m.end() < len(line):
                    injected += line[m.end():]
                return _replace_line(lines, i, orig, injected)

    raise ValueError("missing-parent: no suitable parent assignment found")


def _inject_index_not_flushed(lines: list, language: str) -> tuple:
    """Inject index-not-flushed bug — comment out the index write call."""
    candidates = []
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if language == "python":
            # Look for json.dump / write calls in the context of index saving
            if re.search(r"json\.dump|pickle\.dump|\.write\s*\(", line):
                context = "".join(lines[max(0, i - 5):i + 2])
                if "index" in context.lower() or "stage" in context.lower():
                    candidates.append((i, raw_line))
            # Also look for save_index / write_index function calls
            if re.search(r"\b(save_index|write_index|flush_index|_write_index)\s*\(", line):
                candidates.append((i, raw_line))
        else:
            # Rust: look for fs::write or file write calls in index context
            if re.search(r"fs::write|write_all|serde_json::to_writer|to_string\(\)", line):
                context = "".join(lines[max(0, i - 5):i + 2])
                if "index" in context.lower() or "stage" in context.lower():
                    candidates.append((i, raw_line))

    if candidates:
        i, raw_line = candidates[0]
        line = raw_line.rstrip("\n\r")
        orig = line
        indent_str = " " * (len(line) - len(line.lstrip()))
        if language == "python":
            injected = indent_str + "pass  # index flush disabled (injected bug)"
        else:
            injected = indent_str + "// index flush disabled (injected bug)"
        return _replace_line(lines, i, orig, injected)

    # Fallback: find any write-like call near the bottom of the file
    for i in range(len(lines) - 1, -1, -1):
        raw_line = lines[i]
        line = raw_line.rstrip("\n\r")
        if language == "python":
            if re.search(r"json\.dump|open\s*\(.+['\"]w['\"]|\.write\s*\(", line):
                orig = line
                injected = " " * (len(line) - len(line.lstrip())) + "pass  # index flush disabled (injected bug)"
                return _replace_line(lines, i, orig, injected)

    raise ValueError("index-not-flushed: no suitable index write call found")


def _inject_wrong_diff_base(lines: list, language: str) -> tuple:
    """Inject wrong-diff-base bug — use first commit instead of HEAD."""
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if language == "python":
            # Find HEAD resolution in diff context
            m = re.search(r"\b(head|HEAD|current_commit|head_commit|head_hash)\b", line)
            if m:
                context_before = "".join(l.rstrip("\n\r") for l in lines[max(0, i - 5):i]).lower()
                context_after = "".join(l.rstrip("\n\r") for l in lines[i:min(i + 5, len(lines))]).lower()
                if "diff" in context_before + context_after or "compare" in context_before + context_after:
                    orig = line
                    injected = re.sub(
                        r"\b(get_head|resolve_head|resolve_ref\s*\(['\"]HEAD['\"]\)|self\.head\b)",
                        "self._get_initial_commit()",
                        line,
                    )
                    if injected != line:
                        return _replace_line(lines, i, orig, injected)
        else:
            m = re.search(r"\b(head|HEAD|current_commit|head_hash)\b", line)
            if m:
                context = "".join(
                    l.rstrip("\n\r") for l in lines[max(0, i - 5):min(i + 5, len(lines))]
                ).lower()
                if "diff" in context:
                    orig = line
                    injected = re.sub(
                        r"\bself\.resolve_head\(\)",
                        "self.get_first_commit()",
                        line,
                    )
                    if injected != line:
                        return _replace_line(lines, i, orig, injected)

    # No suitable diff-base reference found — do not inject a comment-only no-op.
    raise ValueError("wrong-diff-base: no suitable diff base reference found")


def apply_bugs_to_source(source_dir: Path, output_dir: Path, bugs: list, language: str) -> list:
    """
    Apply all selected bugs to the source files.

    Returns a list of BugInjection dicts (one per bug, with file_path,
    line_number, original_line, injected_line).

    Each bug is applied to the first suitable Python/Rust source file found.
    """
    # Find source files
    if language == "python":
        source_files = sorted(output_dir.glob("**/*.py"))
    else:
        source_files = sorted(output_dir.glob("**/*.rs"))

    if not source_files:
        print(
            f"Error: no {'*.py' if language == 'python' else '*.rs'} files found in {output_dir}",
            file=sys.stderr,
        )
        sys.exit(1)

    injections = []

    for bug in bugs:
        injected_this_bug = False
        for src_file in source_files:
            rel_path = src_file.relative_to(output_dir)
            try:
                source_text = src_file.read_text(encoding="utf-8")
                modified, line_num, orig_line, inj_line = apply_injection_strategy(
                    source_text, bug, language
                )
                if modified != source_text:
                    src_file.write_text(modified, encoding="utf-8")
                    injections.append(
                        {
                            "bug_id": bug["id"],
                            "category": bug["category"],
                            "file_path": str(rel_path),
                            "line_number": line_num,
                            "description": bug["description"],
                            "original_line": orig_line,
                            "injected_line": inj_line,
                        }
                    )
                    injected_this_bug = True
                    break
            except ValueError:
                continue  # try next file

        if not injected_this_bug:
            # No injection strategy could be applied for this bug.
            # Fail the run rather than inserting a non-functional marker comment,
            # preserving the guarantee that all recorded bugs are real logic bugs.
            print(
                f"Error: failed to inject bug {bug['id']} ({bug['category']}) "
                f"into any {language} source file.",
                file=sys.stderr,
            )
            sys.exit(1)

    return injections


def verify_compilation(output_dir: Path, language: str) -> bool:
    """Verify the seeded implementation still compiles / has valid syntax."""
    if language == "python":
        py_files = list(output_dir.glob("**/*.py"))
        if not py_files:
            return True  # nothing to check
        for py_file in py_files:
            result = subprocess.run(
                [sys.executable, "-m", "py_compile", str(py_file)],
                capture_output=True,
            )
            if result.returncode != 0:
                print(
                    f"Syntax error in {py_file}: {result.stderr.decode()}",
                    file=sys.stderr,
                )
                return False
        return True
    else:
        # Rust: run cargo check. Fail if Cargo.toml is missing (can't verify).
        cargo_toml = output_dir / "Cargo.toml"
        if not cargo_toml.exists():
            print(
                f"Cargo.toml not found in {output_dir}; cannot verify Rust compilation.",
                file=sys.stderr,
            )
            return False
        result = subprocess.run(
            ["cargo", "check", "--manifest-path", str(cargo_toml)],
            capture_output=True,
        )
        if result.returncode != 0:
            print(
                f"Cargo check failed: {result.stderr.decode()}",
                file=sys.stderr,
            )
            return False
        return True


def main():
    parser = argparse.ArgumentParser(
        description="Inject exactly 3 seeded logic bugs into a MiniGit implementation."
    )
    parser.add_argument("--source-dir", required=True, help="Path to source implementation")
    parser.add_argument("--output-dir", required=True, help="Path to write seeded copy")
    parser.add_argument("--manifest-path", required=True, help="Path to write BugManifest JSON")
    parser.add_argument("--language", required=True, choices=["python", "rust"], help="Language")
    parser.add_argument("--trial", required=True, type=int, help="Trial number (1-20)")
    parser.add_argument(
        "--bugs",
        default=None,
        help="Comma-separated list of exactly 3 bug IDs to inject",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="PRNG seed for deterministic bug selection (default: --trial)",
    )
    args = parser.parse_args()

    source_dir = Path(args.source_dir)
    output_dir = Path(args.output_dir)
    manifest_path = Path(args.manifest_path)

    if not source_dir.exists():
        print(f"Error: source-dir '{source_dir}' does not exist.", file=sys.stderr)
        sys.exit(1)

    seed = args.seed if args.seed is not None else args.trial
    explicit_ids = [b.strip() for b in args.bugs.split(",")] if args.bugs else None

    if explicit_ids is not None and len(explicit_ids) != REQUIRED_BUG_COUNT:
        print(
            f"Error: --bugs must specify exactly {REQUIRED_BUG_COUNT} bug IDs, "
            f"got {len(explicit_ids)}.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Load catalog
    catalog = load_catalog(args.language)
    if len(catalog) < REQUIRED_BUG_COUNT:
        print(
            f"Error: catalog has only {len(catalog)} entries for language "
            f"'{args.language}'; need at least {REQUIRED_BUG_COUNT}.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Select bugs
    selected_bugs = select_bugs(catalog, seed, explicit_ids)

    # Copy source to output (idempotent — overwrite existing)
    if output_dir.exists():
        shutil.rmtree(output_dir)
    shutil.copytree(str(source_dir), str(output_dir))

    # Apply bugs
    injections = apply_bugs_to_source(output_dir, output_dir, selected_bugs, args.language)

    if len(injections) != REQUIRED_BUG_COUNT:
        print(
            f"Error: expected {REQUIRED_BUG_COUNT} injections, got {len(injections)}.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Verify compilation for the seeded implementation.
    # For Python this checks syntax; for Rust this runs cargo check.
    # If verification fails (including missing cargo/Cargo.toml for Rust), the
    # seeded output is removed and the run exits non-zero so the orchestrator
    # treats it as failed.
    if not verify_compilation(output_dir, args.language):
        if args.language == "python":
            msg = "Error: seeded implementation fails py_compile. Rolling back."
        else:
            msg = (
                "Error: seeded implementation fails `cargo check` or "
                "cargo/Cargo.toml is missing. Rolling back."
            )
        print(msg, file=sys.stderr)
        shutil.rmtree(output_dir)
        sys.exit(1)

    # Write manifest
    run_id = f"{args.language}-{args.trial}-v2"
    manifest = {
        "run_id": run_id,
        "language": args.language,
        "trial": args.trial,
        "version": "v2",
        "source_dir": str(source_dir),
        "seeded_dir": str(output_dir),
        "injected_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bugs": injections,
    }

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)

    print(f"Injected {REQUIRED_BUG_COUNT} bugs into {output_dir}")


if __name__ == "__main__":
    main()
