# Bugs

Bug injection scripts and seeded-bug catalog for Track 1 Experiments A and B.

## Purpose and Scope

This directory contains:

- **`catalog.json`** — Pre-defined, deterministic bug catalog (12 entries: 6 Python + 6 Rust)
- **`inject.py`** — CLI tool that seeds exactly 3 bugs from the catalog into a MiniGit implementation
- **`test_inject.py`** — Unit tests for `inject.py`

The catalog supports **Track 1 Experiment A** (unconstrained review) and **Experiment B** (Refactory-profile constrained review). All bugs are logic errors that survive compilation (`python3 -m py_compile` or `cargo check`) and do not cause all 30 v2 MiniGit test cases to fail (FR-002).

---

## BugDefinition Schema

Each entry in `catalog.json` follows this schema (see `specs/004-track-1-reviewability/data-model.md` for full details):

```json
{
  "id": "PY-OBO-LOG",
  "category": "off-by-one",
  "language": "python",
  "description": "Human-readable description (max 200 chars)",
  "affected_commands": ["log"],
  "test_impact": "Which v2 tests fail/pass after injection",
  "injection_strategy": "Precise mechanical description of the source transformation"
}
```

| Field | Type | Allowed Values |
|-------|------|----------------|
| `id` | string | Unique; format `{LANG}-{CATEGORY-ABBR}-{COMMAND}` |
| `category` | string | `off-by-one`, `wrong-hash-seed`, `wrong-status`, `missing-parent`, `index-not-flushed`, `wrong-diff-base` |
| `language` | string | `python` or `rust` |
| `description` | string | Max 200 chars |
| `affected_commands` | string[] | Subset of MiniGit commands |
| `test_impact` | string | Human-readable description of which tests are affected |
| `injection_strategy` | string | Deterministic, unambiguous transformation description |

### Bug IDs

| Python ID | Rust ID | Category | Affected Command |
|-----------|---------|----------|-----------------|
| `PY-OBO-LOG` | `RS-OBO-LOG` | `off-by-one` | `log` |
| `PY-HASH-SEED` | `RS-HASH-SEED` | `wrong-hash-seed` | `commit`, `log`, `show` |
| `PY-STATUS-STAGE` | `RS-STATUS-STAGE` | `wrong-status` | `status` |
| `PY-PARENT-NULL` | `RS-PARENT-NULL` | `missing-parent` | `commit`, `log` |
| `PY-INDEX-FLUSH` | `RS-INDEX-FLUSH` | `index-not-flushed` | `add`, `rm`, `status` |
| `PY-DIFF-BASE` | `RS-DIFF-BASE` | `wrong-diff-base` | `diff` |

---

## Adding a New Bug Template

1. Open `bugs/catalog.json`.
2. Append a new JSON object following the schema above.
3. Choose an `id` not already in the catalog; use the format `{LANG}-{CATEGORY-ABBR}-{COMMAND}`.
4. Set `language` to `python` or `rust`.
5. Write a deterministic `injection_strategy` that describes the exact source transformation (no ambiguity).
6. Verify the injected bug does **not** prevent compilation and does **not** trip all 30 v2 tests.
7. Run `python3 -c "import json; c=json.load(open('bugs/catalog.json')); [print(e['id']) for e in c]"` to confirm the new entry loads.

---

## inject.py Usage

Inject exactly 3 bugs from the catalog into a MiniGit implementation:

```bash
python3 bugs/inject.py \
  --source-dir generated/minigit-python-1-v2 \
  --output-dir experiments/track1/seeded/python-1-v2 \
  --manifest-path experiments/track1/manifests/python-1-v2.json \
  --language python \
  --trial 1
```

### Flags

| Flag | Required | Description |
|------|----------|-------------|
| `--source-dir` | Yes | Path to the original MiniGit implementation |
| `--output-dir` | Yes | Where to write the seeded copy |
| `--manifest-path` | Yes | Where to write the BugManifest JSON |
| `--language` | Yes | `python` or `rust` |
| `--trial` | Yes | Trial number (used in `run_id` and as default PRNG seed) |
| `--bugs` | No | Comma-separated list of exactly 3 bug IDs to inject |
| `--seed` | No | PRNG seed for deterministic selection (default: `--trial`) |

### Deterministic Bug Selection

When `--bugs` is omitted, bugs are selected deterministically using Python's `random.seed(seed)` seeded with `--seed` (defaulting to `--trial`). This guarantees reproducible injection across runs.

### Output (BugManifest JSON)

```json
{
  "run_id": "python-1-v2",
  "language": "python",
  "trial": 1,
  "version": "v2",
  "source_dir": "generated/minigit-python-1-v2",
  "seeded_dir": "experiments/track1/seeded/python-1-v2",
  "injected_at": "2026-03-21T10:00:00Z",
  "bugs": [
    {
      "bug_id": "PY-OBO-LOG",
      "category": "off-by-one",
      "file_path": "minigit.py",
      "line_number": 87,
      "description": "Log stops one commit early",
      "original_line": "    while parent:",
      "injected_line": "    while parent and depth < max_depth - 1:"
    }
  ]
}
```

---

## Running Tests

```bash
python3 -m pytest bugs/test_inject.py -v
```
