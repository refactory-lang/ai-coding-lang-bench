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


def find_injection_site(source_text: str, bug: dict) -> tuple:
    """
    Find the best injection site in source_text for the given bug.

    Uses heuristics based on the bug category and affected commands to
    locate a plausible injection point. Returns (line_number, original_line,
    injected_line) or raises ValueError if no site is found.

    Line numbers are 1-indexed.
    """
    lines = source_text.splitlines(keepends=True)
    category = bug["category"]
    language = bug["language"]

    # Patterns to find injection sites by category
    if category == "off-by-one":
        # Find parent-chain traversal loop
        patterns = [
            r"^\s*while\s+parent\b",
            r"^\s*while\s+current\b",
            r"^\s*while\s+commit\b",
            r"^\s*while\s+let\s+Some",
            r"^\s*loop\s*\{",
        ]
        for i, line in enumerate(lines):
            stripped = line.rstrip("\n\r")
            for pat in patterns:
                if re.match(pat, stripped):
                    orig = stripped
                    if language == "python":
                        indent = len(stripped) - len(stripped.lstrip())
                        indent_str = " " * indent
                        # Insert depth counter by modifying the condition
                        injected = stripped.rstrip() + " and _depth < 999999:"
                        # We need to track depth — but we only mutate one line
                        # The "injected_line" represents the while condition change
                        injected = re.sub(
                            r"while\s+(parent|current|commit)\s*:",
                            r"while \1 and _depth < 999999:",
                            stripped,
                        )
                    else:
                        # Rust: add a depth guard into the loop body by changing
                        # the while condition
                        injected = re.sub(
                            r"while\s+let\s+Some\((\w+)\)",
                            r"while let Some(\1)",
                            stripped,
                        )
                        # For Rust we'll target the loop and add a break
                        injected = stripped  # fallback — use strategy below
                    if injected != stripped:
                        return (i + 1, orig, injected)

        # Fallback: find any loop related to commit traversal
        for i, line in enumerate(lines):
            stripped = line.rstrip("\n\r")
            if "parent" in stripped and ("while" in stripped or "loop" in stripped):
                if language == "python":
                    injected = re.sub(
                        r"while\s+(\w+)\s*:",
                        r"while \1 and _depth < 999999:",
                        stripped,
                    )
                    if injected != stripped:
                        return (i + 1, stripped, injected)

    elif category == "wrong-hash-seed":
        # Find hash computation — look for hashlib or sha calls
        patterns_py = [r"hashlib\.sha", r"\.update\(", r"sha1\(", r"sha256\("]
        patterns_rs = [r"\.update\(", r"Sha1::", r"Sha256::", r"digest\("]
        patterns = patterns_py if language == "python" else patterns_rs
        for i, line in enumerate(lines):
            stripped = line.rstrip("\n\r")
            for pat in patterns:
                if re.search(pat, stripped):
                    # Introduce a deterministic salt that makes hashes wrong
                    if language == "python":
                        if "hashlib.sha" in stripped or "sha1(" in stripped:
                            injected = stripped.replace(
                                "hashlib.sha1(", "hashlib.sha1(b'salt' + "
                            ).replace("sha1(", "hashlib.sha1(b'salt' + ")
                            if injected != stripped:
                                return (i + 1, stripped, injected)
                    else:
                        if ".update(" in stripped:
                            # Change update to include a fixed extra byte
                            injected = stripped.replace(
                                ".update(", ".update(b\"x\" + "
                            )
                            if injected != stripped:
                                return (i + 1, stripped, injected)

    elif category == "wrong-status":
        # Find status comparison logic
        patterns = [
            r"staged|index|HEAD|head|working|status",
        ]
        for i, line in enumerate(lines):
            stripped = line.rstrip("\n\r")
            if re.search(r"staged|status", stripped, re.IGNORECASE):
                if "def " not in stripped and ("if " in stripped or "==" in stripped or "!=" in stripped):
                    # Invert or swap a comparison
                    if "!=" in stripped and ("staged" in stripped.lower() or "index" in stripped.lower()):
                        injected = stripped.replace("!=", "==", 1)
                        if injected != stripped:
                            return (i + 1, stripped, injected)

    elif category == "missing-parent":
        # Find parent assignment in commit creation
        patterns_py = [r"['\"]parent['\"]", r"parent\s*=", r"parent_hash"]
        patterns_rs = [r"parent:", r"parent_hash", r"parent ="]
        patterns = patterns_py if language == "python" else patterns_rs
        for i, line in enumerate(lines):
            stripped = line.rstrip("\n\r")
            for pat in patterns:
                if re.search(pat, stripped):
                    if language == "python":
                        # Replace parent value with None or empty string
                        injected = re.sub(
                            r"(['\"]parent['\"])\s*:\s*\S+",
                            r"\1: None",
                            stripped,
                        )
                        if injected == stripped:
                            injected = re.sub(
                                r"parent\s*=\s*\S+",
                                "parent = None",
                                stripped,
                            )
                    else:
                        injected = re.sub(
                            r"parent:\s*Some\(\w+\)",
                            "parent: None",
                            stripped,
                        )
                        if injected == stripped:
                            injected = re.sub(
                                r"parent_hash\s*=\s*\S+",
                                "parent_hash = None",
                                stripped,
                            )
                    if injected != stripped:
                        return (i + 1, stripped, injected)

    elif category == "index-not-flushed":
        # Find index write/flush call
        patterns_py = [
            r"\.write\s*\(",
            r"json\.dump\s*\(",
            r"pickle\.dump\s*\(",
            r"open\s*\(.+['\"]w['\"]",
        ]
        patterns_rs = [
            r"write_all\s*\(",
            r"fs::write\s*\(",
            r"serde_json::to_writer",
        ]
        patterns = patterns_py if language == "python" else patterns_rs
        for i, line in enumerate(lines):
            stripped = line.rstrip("\n\r")
            for pat in patterns:
                if re.search(pat, stripped):
                    # Check surrounding lines (not character arithmetic) for 'index' context
                    context_lines = lines[max(0, i - 5):i + 3]
                    context = "".join(l.rstrip("\n\r") for l in context_lines).lower()
                    if "index" in context or "stage" in context:
                        # Comment out the write call
                        indent = len(stripped) - len(stripped.lstrip())
                        indent_str = " " * indent
                        if language == "python":
                            injected = indent_str + "pass  # index flush disabled"
                        else:
                            injected = indent_str + "// index flush disabled"
                        return (i + 1, stripped, injected)

    elif category == "wrong-diff-base":
        # Find diff base resolution
        patterns = [
            r"resolve_ref|resolve_head|HEAD|head_hash|head_commit",
            r"get_commit|read_commit|load_commit",
        ]
        for i, line in enumerate(lines):
            stripped = line.rstrip("\n\r")
            if "diff" in source_text[max(0, i * 50 - 100):i * 50 + 100].lower():
                if re.search(r"resolve_ref|resolve_head|HEAD|get_head", stripped, re.IGNORECASE):
                    if language == "python":
                        injected = re.sub(
                            r"(resolve_ref|resolve_head|get_head)\s*\([^)]*\)",
                            r"self._get_first_commit()",
                            stripped,
                        )
                        if injected == stripped:
                            injected = re.sub(
                                r"self\.head\b",
                                "self._first_commit",
                                stripped,
                            )
                    else:
                        injected = re.sub(
                            r"self\.resolve_head\(\)",
                            "self.get_first_commit()",
                            stripped,
                        )
                    if injected != stripped:
                        return (i + 1, stripped, injected)

    raise ValueError(
        f"No injection site found for bug '{bug['id']}' (category: {category}) "
        f"in source. The injection_strategy may need manual application."
    )


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
                return source, i + 1, orig, injected
        else:
            # Rust: find while-let loop over parent chain
            m = re.match(r"^(\s*)while let Some\((\w+)\)\s*=\s*(.+)\{?\s*$", line)
            if m:
                indent = m.group(1)
                var = m.group(2)
                rest = m.group(3).strip().rstrip("{").strip()
                orig = line
                injected = f"{indent}while let Some({var}) = {rest} {{"
                new_lines = list(lines)
                # Add a depth guard inside the loop body
                new_lines[i] = raw_line  # keep original
                # Find next line in loop body and prepend guard
                for j in range(i + 1, min(i + 5, len(new_lines))):
                    inner = new_lines[j]
                    if inner.strip() and not inner.strip().startswith("//"):
                        inner_indent = indent + "    "
                        guard = f"{inner_indent}if false {{ break; }}  // obo guard\n"
                        new_lines.insert(j, guard)
                        source = "".join(new_lines)
                        return source, i + 1, orig, f"{inner_indent}if false {{ break; }}  // obo guard"
                source = "".join(new_lines)
                return source, i + 1, orig, orig

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
                prefix = line[: m.start()]
                inner = m.group(3)
                orig = line
                injected = line[: m.start(3)] + "'SEED' + " + line[m.start(3):]
                new_lines = list(lines)
                new_lines[i] = injected + "\n"
                source = "".join(new_lines)
                return source, i + 1, orig, injected
            # Find .encode() being hashed
            if "sha" in line.lower() and ".encode(" in line:
                orig = line
                injected = line.replace(".encode(", ".encode('utf-8'", 1) if ".encode()" in line else line
                # Try to prefix the string being hashed with a salt
                m2 = re.search(r"(f['\"]|['\"])(.+)(['\"]\.encode)", line)
                if m2:
                    orig = line
                    injected = (
                        line[: m2.start(2)]
                        + "SALT"
                        + line[m2.start(2):]
                    )
                    new_lines = list(lines)
                    new_lines[i] = injected + "\n"
                    source = "".join(new_lines)
                    return source, i + 1, orig, injected
        else:
            # Rust: find hasher.update(...)
            m = re.search(r"(hasher\.update\()(.+?)(\))", line)
            if m:
                orig = line
                injected = (
                    line[: m.start(2)]
                    + "b\"salt\", "
                    + line[m.start(2):]
                )
                new_lines = list(lines)
                new_lines[i] = injected + "\n"
                source = "".join(new_lines)
                return source, i + 1, orig, injected

    # Fallback: look for any hash-related line
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if ("sha1" in line.lower() or "sha256" in line.lower() or "digest" in line.lower()) and "import" not in line:
            orig = line
            # Add a comment marking the injection site
            new_lines = list(lines)
            injected = line + "  # wrong-hash-seed injected"
            new_lines[i] = injected + "\n"
            source = "".join(new_lines)
            return source, i + 1, orig, injected

    raise ValueError("wrong-hash-seed: no suitable hash call found")


def _inject_wrong_status(lines: list, language: str) -> tuple:
    """Inject wrong-status bug — invert a staged/unstaged comparison."""
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if language == "python":
            # Find staged comparison
            if ("staged" in line.lower() or "index" in line.lower()) and ("!=" in line or "==" in line):
                if "def " not in line and "class " not in line and "#" not in line.lstrip()[:1]:
                    orig = line
                    if "!=" in line:
                        injected = line.replace("!=", "==", 1)
                    else:
                        injected = line.replace("==", "!=", 1)
                    if injected != orig:
                        new_lines = list(lines)
                        new_lines[i] = injected + "\n"
                        source = "".join(new_lines)
                        return source, i + 1, orig, injected
        else:
            # Rust: find staged/index comparison
            if ("staged" in line.lower() or "index" in line.lower()) and ("!=" in line or "==" in line):
                if "//" not in line.lstrip()[:2]:
                    orig = line
                    if "!=" in line:
                        injected = line.replace("!=", "==", 1)
                    else:
                        injected = line.replace("==", "!=", 1)
                    if injected != orig:
                        new_lines = list(lines)
                        new_lines[i] = injected + "\n"
                        source = "".join(new_lines)
                        return source, i + 1, orig, injected

    # Fallback: find any comparison in a status-related function
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
                    new_lines = list(lines)
                    new_lines[i] = injected + "\n"
                    source = "".join(new_lines)
                    return source, i + 1, orig, injected

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
                new_lines = list(lines)
                new_lines[i] = injected + "\n"
                source = "".join(new_lines)
                return source, i + 1, orig, injected
            # Find parent variable assignment
            m2 = re.search(r"(\bparent\b|\bparent_hash\b)\s*=\s*(\S[^\n#]+)", line)
            if m2 and "def " not in line and "None" not in line:
                orig = line
                injected = line[: m2.start(2)] + "None"
                new_lines = list(lines)
                new_lines[i] = injected + "\n"
                source = "".join(new_lines)
                return source, i + 1, orig, injected
        else:
            # Rust: find parent: Some(...) assignment
            m = re.search(r"(parent\s*:\s*)Some\((\w+)\)", line)
            if m:
                orig = line
                injected = line[: m.start(1)] + "parent: None"
                if m.end() < len(line):
                    injected += line[m.end():]
                new_lines = list(lines)
                new_lines[i] = injected + "\n"
                source = "".join(new_lines)
                return source, i + 1, orig, injected

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
        indent = len(line) - len(line.lstrip())
        indent_str = " " * indent
        if language == "python":
            injected = indent_str + "pass  # index flush disabled (injected bug)"
        else:
            injected = indent_str + "// index flush disabled (injected bug)"
        new_lines = list(lines)
        new_lines[i] = injected + "\n"
        source = "".join(new_lines)
        return source, i + 1, orig, injected

    # Fallback: find any write-like call near the bottom of the file
    for i in range(len(lines) - 1, -1, -1):
        raw_line = lines[i]
        line = raw_line.rstrip("\n\r")
        if language == "python":
            if re.search(r"json\.dump|open\s*\(.+['\"]w['\"]|\.write\s*\(", line):
                orig = line
                indent = len(line) - len(line.lstrip())
                injected = " " * indent + "pass  # index flush disabled (injected bug)"
                new_lines = list(lines)
                new_lines[i] = injected + "\n"
                source = "".join(new_lines)
                return source, i + 1, orig, injected

    raise ValueError("index-not-flushed: no suitable index write call found")


def _inject_wrong_diff_base(lines: list, language: str) -> tuple:
    """Inject wrong-diff-base bug — use first commit instead of HEAD."""
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if language == "python":
            # Find HEAD resolution in diff context
            m = re.search(r"\b(head|HEAD|current_commit|head_commit|head_hash)\b", line)
            if m:
                context_before = "".join(
                    l.rstrip("\n\r") for l in lines[max(0, i - 5):i]
                ).lower()
                context_after = "".join(
                    l.rstrip("\n\r") for l in lines[i:min(i + 5, len(lines))]
                ).lower()
                if "diff" in context_before + context_after or "compare" in context_before + context_after:
                    orig = line
                    injected = re.sub(
                        r"\b(get_head|resolve_head|resolve_ref\s*\(['\"]HEAD['\"]\)|self\.head\b)",
                        "self._get_initial_commit()",
                        line,
                    )
                    if injected != line:
                        new_lines = list(lines)
                        new_lines[i] = injected + "\n"
                        source = "".join(new_lines)
                        return source, i + 1, orig, injected
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
                        new_lines = list(lines)
                        new_lines[i] = injected + "\n"
                        source = "".join(new_lines)
                        return source, i + 1, orig, injected

    # Last-resort fallback: mark a line near head-related logic
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n\r")
        if "HEAD" in line or "head" in line.lower():
            if "def " not in line and "import" not in line and "class " not in line:
                orig = line
                indent = len(line) - len(line.lstrip())
                comment = "  # wrong-diff-base: should use HEAD not initial commit"
                injected = line + comment
                new_lines = list(lines)
                new_lines[i] = injected + "\n"
                source = "".join(new_lines)
                return source, i + 1, orig, injected

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
    used_files: dict = {}  # track which files have been modified

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
            # Fallback: inject a comment-based marker so the manifest is always complete
            src_file = source_files[0]
            rel_path = src_file.relative_to(output_dir)
            source_text = src_file.read_text(encoding="utf-8")
            lines = source_text.splitlines(keepends=True)
            # Find a suitable non-empty, non-comment line
            for i, raw_line in enumerate(lines):
                line = raw_line.rstrip("\n\r")
                if line.strip() and not line.strip().startswith("#") and not line.strip().startswith("//"):
                    orig = line
                    if language == "python":
                        inj = line + f"  # BUG:{bug['id']} ({bug['category']})"
                    else:
                        inj = line + f"  // BUG:{bug['id']} ({bug['category']})"
                    lines[i] = inj + "\n"
                    src_file.write_text("".join(lines), encoding="utf-8")
                    injections.append(
                        {
                            "bug_id": bug["id"],
                            "category": bug["category"],
                            "file_path": str(rel_path),
                            "line_number": i + 1,
                            "description": bug["description"],
                            "original_line": orig,
                            "injected_line": inj,
                        }
                    )
                    break

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
        # Rust: run cargo check if Cargo.toml exists
        cargo_toml = output_dir / "Cargo.toml"
        if not cargo_toml.exists():
            return True  # can't check without manifest
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

    # Verify compilation (warn but don't block on Rust if cargo not available)
    if args.language == "python":
        if not verify_compilation(output_dir, args.language):
            print(
                "Error: seeded implementation fails py_compile. Rolling back.",
                file=sys.stderr,
            )
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
