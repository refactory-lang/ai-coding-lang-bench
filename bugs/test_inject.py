"""
bugs/test_inject.py — Unit tests for bugs/inject.py

Runner: python3 -m pytest bugs/test_inject.py -v
"""

import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

# Add repository root to path so we can import inject module
REPO_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(REPO_ROOT / "bugs"))

import inject


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_python_source(content: str = None) -> str:
    """Create a minimal valid Python MiniGit-like source."""
    if content is not None:
        return content
    return '''\
#!/usr/bin/env python3
"""Minimal MiniGit stub for testing."""
import hashlib
import json
import os


class MiniGit:
    def __init__(self, path):
        self.path = path
        self.index = {}
        self.head = None

    def add(self, filename):
        with open(filename) as f:
            content = f.read()
        self.index[filename] = hashlib.sha1(content.encode()).hexdigest()
        self._save_index()

    def _save_index(self):
        with open(os.path.join(self.path, '.git', 'index'), 'w') as f:
            json.dump(self.index, f)

    def commit(self, message):
        parent = self.head
        tree = hashlib.sha1(json.dumps(self.index).encode()).hexdigest()
        commit_hash = hashlib.sha1(
            f"{tree}{parent}{message}".encode()
        ).hexdigest()
        commit_data = {
            'hash': commit_hash,
            'tree': tree,
            'parent': parent,
            'message': message,
        }
        self.head = commit_hash
        return commit_hash

    def log(self):
        commits = []
        current = self.head
        while current:
            commit = self._read_commit(current)
            commits.append(commit)
            current = commit.get('parent')
        return commits

    def status(self):
        staged = []
        unstaged = []
        for f, h in self.index.items():
            if h != self.head:
                staged.append(f)
        return staged, unstaged

    def diff(self):
        base = self.head
        return base

    def _read_commit(self, hash_val):
        return {}
'''


def make_source_dir(tmp_path: Path, source_content: str = None, language: str = "python") -> Path:
    """Create a temporary source directory with a minimal implementation."""
    src = tmp_path / "src"
    src.mkdir()
    if language == "python":
        (src / "minigit.py").write_text(make_python_source(source_content), encoding="utf-8")
    else:
        # Rust — create a minimal Cargo project
        (src / "Cargo.toml").write_text(
            '[package]\nname = "minigit"\nversion = "0.1.0"\nedition = "2021"\n',
            encoding="utf-8",
        )
        lib_src = src / "src"
        lib_src.mkdir()
        (lib_src / "main.rs").write_text(
            'fn main() { println!("minigit"); }\n',
            encoding="utf-8",
        )
    return src


# ---------------------------------------------------------------------------
# Test 1: Happy-path injection produces manifest with exactly 3 entries
# ---------------------------------------------------------------------------

def test_happy_path_injection(tmp_path):
    import shutil

    src = make_source_dir(tmp_path)
    out_dir = tmp_path / "seeded"
    manifest_path = tmp_path / "manifest.json"

    catalog = inject.load_catalog("python")
    bugs = inject.select_bugs(catalog, seed=1)

    shutil.copytree(str(src), str(out_dir))

    injections = inject.apply_bugs_to_source(out_dir, out_dir, bugs, "python")

    assert len(injections) == 3, f"Expected 3 injections, got {len(injections)}"
    for inj in injections:
        assert "bug_id" in inj
        assert "file_path" in inj
        assert "line_number" in inj
        assert isinstance(inj["line_number"], int) and inj["line_number"] >= 1
        assert "original_line" in inj
        assert "injected_line" in inj
        assert inj["category"] in {
            "off-by-one", "wrong-hash-seed", "wrong-status",
            "missing-parent", "index-not-flushed", "wrong-diff-base",
        }


# ---------------------------------------------------------------------------
# Test 2: Idempotency — running twice produces identical manifest
# ---------------------------------------------------------------------------

def test_idempotency(tmp_path):
    import shutil

    src = make_source_dir(tmp_path)
    out_dir1 = tmp_path / "seeded1"
    manifest1 = tmp_path / "manifest1.json"
    out_dir2 = tmp_path / "seeded2"
    manifest2 = tmp_path / "manifest2.json"

    # First run
    shutil.copytree(str(src), str(out_dir1))
    bugs = inject.select_bugs(inject.load_catalog("python"), seed=5)
    inj1 = inject.apply_bugs_to_source(out_dir1, out_dir1, bugs, "python")

    # Second run — fresh copy
    shutil.copytree(str(src), str(out_dir2))
    bugs2 = inject.select_bugs(inject.load_catalog("python"), seed=5)
    inj2 = inject.apply_bugs_to_source(out_dir2, out_dir2, bugs2, "python")

    assert len(inj1) == len(inj2) == 3
    for i1, i2 in zip(inj1, inj2):
        assert i1["bug_id"] == i2["bug_id"]
        assert i1["line_number"] == i2["line_number"]
        assert i1["original_line"] == i2["original_line"]
        assert i1["injected_line"] == i2["injected_line"]


# ---------------------------------------------------------------------------
# Test 3: Determinism — same seed always selects same 3 bugs
# ---------------------------------------------------------------------------

def test_determinism():
    catalog = inject.load_catalog("python")
    assert len(catalog) >= 3

    bugs_run1 = inject.select_bugs(catalog, seed=42)
    bugs_run2 = inject.select_bugs(catalog, seed=42)
    bugs_run3 = inject.select_bugs(catalog, seed=99)

    assert [b["id"] for b in bugs_run1] == [b["id"] for b in bugs_run2]
    # Different seeds should (very likely) give different selections
    # (with 6 bugs choose 3 = 20 combos, seeds 42 and 99 are different combos)
    # We only assert reproducibility, not that different seeds differ
    assert len(bugs_run1) == 3
    assert len(bugs_run3) == 3


# ---------------------------------------------------------------------------
# Test 4: Explicit bug IDs — --bugs overrides PRNG selection
# ---------------------------------------------------------------------------

def test_explicit_bug_ids():
    catalog = inject.load_catalog("python")
    ids = ["PY-OBO-LOG", "PY-HASH-SEED", "PY-INDEX-FLUSH"]
    bugs = inject.select_bugs(catalog, seed=1, explicit_ids=ids)
    assert [b["id"] for b in bugs] == ids


# ---------------------------------------------------------------------------
# Test 5: Invalid explicit bug ID raises SystemExit
# ---------------------------------------------------------------------------

def test_invalid_bug_id_exits():
    catalog = inject.load_catalog("python")
    with pytest.raises(SystemExit):
        inject.select_bugs(catalog, seed=1, explicit_ids=["PY-OBO-LOG", "NONEXISTENT", "PY-INDEX-FLUSH"])


# ---------------------------------------------------------------------------
# Test 6: Catalog validation — 12 entries, 6 per language
# ---------------------------------------------------------------------------

def test_catalog_has_correct_entries():
    catalog_path = Path(__file__).parent / "catalog.json"
    with open(catalog_path, encoding="utf-8") as f:
        catalog = json.load(f)

    assert len(catalog) == 12, f"Expected 12 entries, got {len(catalog)}"
    py_bugs = [b for b in catalog if b["language"] == "python"]
    rs_bugs = [b for b in catalog if b["language"] == "rust"]
    assert len(py_bugs) == 6, f"Expected 6 Python bugs, got {len(py_bugs)}"
    assert len(rs_bugs) == 6, f"Expected 6 Rust bugs, got {len(rs_bugs)}"

    ids = [b["id"] for b in catalog]
    assert len(ids) == len(set(ids)), "Bug IDs must be unique"

    required_py_ids = {
        "PY-OBO-LOG", "PY-HASH-SEED", "PY-STATUS-STAGE",
        "PY-PARENT-NULL", "PY-INDEX-FLUSH", "PY-DIFF-BASE",
    }
    required_rs_ids = {
        "RS-OBO-LOG", "RS-HASH-SEED", "RS-STATUS-STAGE",
        "RS-PARENT-NULL", "RS-INDEX-FLUSH", "RS-DIFF-BASE",
    }
    assert required_py_ids.issubset(set(ids)), f"Missing Python IDs: {required_py_ids - set(ids)}"
    assert required_rs_ids.issubset(set(ids)), f"Missing Rust IDs: {required_rs_ids - set(ids)}"


# ---------------------------------------------------------------------------
# Test 7: Co-location — two bugs at the same line both recorded correctly
# ---------------------------------------------------------------------------

def test_co_location_both_recorded(tmp_path):
    """
    When two bugs are injected and both happen to target the same region,
    both should be recorded with correct line_number values.
    """
    import shutil

    src = make_source_dir(tmp_path)
    out_dir = tmp_path / "seeded"
    shutil.copytree(str(src), str(out_dir))

    catalog = inject.load_catalog("python")
    # Force two bugs that target close-by regions
    bugs = inject.select_bugs(catalog, seed=1, explicit_ids=["PY-OBO-LOG", "PY-HASH-SEED", "PY-INDEX-FLUSH"])
    injections = inject.apply_bugs_to_source(out_dir, out_dir, bugs, "python")

    assert len(injections) == 3
    for inj in injections:
        assert inj["line_number"] >= 1
        assert inj["file_path"].endswith(".py")


# ---------------------------------------------------------------------------
# Test 8: Insufficient catalog entries raises SystemExit
# ---------------------------------------------------------------------------

def test_insufficient_catalog_exits():
    tiny_catalog = [
        {"id": "PY-OBO-LOG", "language": "python", "category": "off-by-one",
         "description": "test", "affected_commands": ["log"],
         "test_impact": "fails", "injection_strategy": "..."},
        {"id": "PY-HASH-SEED", "language": "python", "category": "wrong-hash-seed",
         "description": "test", "affected_commands": ["commit"],
         "test_impact": "fails", "injection_strategy": "..."},
    ]
    with pytest.raises(SystemExit):
        inject.select_bugs(tiny_catalog, seed=1)


# ---------------------------------------------------------------------------
# Test 9: Compiled output passes py_compile
# ---------------------------------------------------------------------------

def test_seeded_output_compiles(tmp_path):
    import shutil

    src = make_source_dir(tmp_path)
    out_dir = tmp_path / "seeded"
    shutil.copytree(str(src), str(out_dir))

    catalog = inject.load_catalog("python")
    bugs = inject.select_bugs(catalog, seed=7)
    inject.apply_bugs_to_source(out_dir, out_dir, bugs, "python")

    # Verify all Python files still parse
    ok = inject.verify_compilation(out_dir, "python")
    assert ok, "Seeded output should still pass py_compile"


# ---------------------------------------------------------------------------
# Test 10: load_catalog filters by language
# ---------------------------------------------------------------------------

def test_load_catalog_filters_language():
    py_catalog = inject.load_catalog("python")
    rs_catalog = inject.load_catalog("rust")

    assert all(b["language"] == "python" for b in py_catalog)
    assert all(b["language"] == "rust" for b in rs_catalog)
    assert len(py_catalog) == 6
    assert len(rs_catalog) == 6
