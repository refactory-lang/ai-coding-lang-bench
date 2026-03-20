# CLI Contracts: Track 1 — Reviewability Gap Tools

**Feature Branch**: `004-track-1-reviewability`  
**Created**: 2026-03-20

These contracts define the command-line interface for all Track 1 tools.
All tools accept `--help`, write structured output to files (not stdout),
and exit with code 0 on success or non-zero on failure.

---

## bugs/inject.py — Bug Injection Tool

### Purpose
Inject exactly 3 seeded logic bugs into a MiniGit implementation and produce
a machine-readable manifest.

### Invocation
```
python3 bugs/inject.py \
  --source-dir PATH \
  --output-dir PATH \
  --manifest-path PATH \
  --language LANG \
  --trial N \
  [--bugs BUG_ID,BUG_ID,BUG_ID] \
  [--seed INT]
```

### Arguments

| Flag | Required | Type | Description |
|------|----------|------|-------------|
| `--source-dir` | Yes | path | Absolute or relative path to the original MiniGit implementation directory |
| `--output-dir` | Yes | path | Path where the seeded copy will be written (created if absent) |
| `--manifest-path` | Yes | path | Path to write the BugManifest JSON file |
| `--language` | Yes | string | `python` or `rust` |
| `--trial` | Yes | integer | Trial number (1–20); used in `run_id` |
| `--bugs` | No | string | Comma-separated list of exactly 3 bug IDs to inject; if omitted, 3 bugs are selected deterministically from the catalog using `--seed` |
| `--seed` | No | integer | PRNG seed for deterministic bug selection when `--bugs` is omitted (default: `trial`) |

### Output
- Writes a complete copy of `--source-dir` to `--output-dir` with mutations applied.
- Writes a BugManifest JSON file to `--manifest-path`.
- Prints `Injected 3 bugs into {output-dir}` to stdout on success.
- Exit code 0 on success; 1 on any error (error message to stderr).

### Constraints
- Exactly 3 bugs must be injected; the tool MUST error if fewer than 3 applicable catalog entries exist for the language.
- The seeded copy must compile / have valid syntax (verified by running `python3 -m py_compile` for Python or `cargo check` for Rust before exit).
- Idempotent: re-running with the same arguments overwrites the output-dir and manifest.

### Example
```bash
python3 bugs/inject.py \
  --source-dir generated/minigit-python-1-v2 \
  --output-dir experiments/track1/seeded/python-1-v2 \
  --manifest-path experiments/track1/manifests/python-1-v2.json \
  --language python \
  --trial 1
```

---

## review/harness.py — Review Harness

### Purpose
Submit a seeded MiniGit implementation to the Anthropic Claude API as a single
non-agentic review call and save the structured response.

### Invocation
```
python3 review/harness.py \
  --seeded-dir PATH \
  --manifest-path PATH \
  --output-path PATH \
  --condition CONDITION \
  [--model MODEL] \
  [--max-tokens INT] \
  [--api-key-env VAR]
```

### Arguments

| Flag | Required | Type | Description |
|------|----------|------|-------------|
| `--seeded-dir` | Yes | path | Path to the seeded implementation directory |
| `--manifest-path` | Yes | path | Path to the BugManifest JSON (for `run_id` metadata) |
| `--output-path` | Yes | path | Path to write the ReviewResponse JSON |
| `--condition` | Yes | string | `unconstrained` or `refactory-profile` |
| `--model` | No | string | Anthropic model string (default: `claude-opus-4.6`) |
| `--max-tokens` | No | integer | Max output tokens (default: `4096`) |
| `--api-key-env` | No | string | Environment variable holding the API key (default: `ANTHROPIC_API_KEY`) |

### Output
- Writes a ReviewResponse JSON file to `--output-path`.
- Prints `Review complete: {run_id} [{condition}] — {input_tokens} in / {output_tokens} out` to stdout.
- On missing data (all retries exhausted): writes ReviewResponse with `missing_data: true`, exits with code 2 (distinguishable from crash).
- Exit code 0 on success; 1 on argument/auth error; 2 on missing data after retries.

### Constraints
- No `tools` parameter in the API call (non-agentic).
- No follow-up turns (single message pair: system + user).
- Source files are concatenated in alphabetical order; each prefixed with a `### filename` header.
- `price_per_1k_input_usd` and `price_per_1k_output_usd` must be recorded in the response (configurable in `review/pricing.json`).

### Example
```bash
python3 review/harness.py \
  --seeded-dir experiments/track1/seeded/python-1-v2 \
  --manifest-path experiments/track1/manifests/python-1-v2.json \
  --output-path experiments/track1/reviews/unconstrained/python-1-v2.json \
  --condition unconstrained \
  --model claude-opus-4.6
```

---

## review/score.py — Scoring Tool

### Purpose
Compare saved review responses against the bug manifest and produce per-run
metrics (DDR and FPR).

### Invocation
```
python3 review/score.py \
  --manifest-path PATH \
  --review-path PATH \
  --output-path PATH \
  [--line-tolerance INT]
```

### Arguments

| Flag | Required | Type | Description |
|------|----------|------|-------------|
| `--manifest-path` | Yes | path | Path to the BugManifest JSON |
| `--review-path` | Yes | path | Path to the ReviewResponse JSON |
| `--output-path` | Yes | path | Path to write the RunMetrics JSON |
| `--line-tolerance` | No | integer | Line-range matching tolerance in lines (default: `5`) |

### Output
- Writes a RunMetrics JSON file to `--output-path`.
- Prints `Scored {run_id} [{condition}]: DDR={ddr:.2f} FPR={fpr:.2f}` to stdout.
- Exit code 0 always (missing data runs scored as `null` DDR/FPR).

### Scoring Logic
A ReviewFinding at (file, line_start, line_end) is a TP for bug *B* (injected
at `file_path`, `line_number`) if:
```
finding.file_path == bug.file_path
AND |finding.line_start - bug.line_number| <= line_tolerance
```
If `finding.line_start` is null, the finding cannot match any bug (classified
as FP if the file matches, dropped if file doesn't match).

Co-located bugs: if multiple bugs share `(file_path, line_number)`, any finding
that matches the location is a TP for **all** those bugs (per spec clarification).

### Example
```bash
python3 review/score.py \
  --manifest-path experiments/track1/manifests/python-1-v2.json \
  --review-path experiments/track1/reviews/unconstrained/python-1-v2.json \
  --output-path experiments/track1/metrics/python-1-v2-unconstrained.json
```

---

## analysis/token_analysis.py — Token & Cost Analyser

### Purpose
Read all saved ReviewResponse files from Experiments A and B, extract token
counts, compute costs, and produce per-group cost summaries (Experiment H).

### Invocation
```
python3 analysis/token_analysis.py \
  --reviews-dir PATH \
  --output-csv PATH \
  --output-summary PATH
```

### Arguments

| Flag | Required | Type | Description |
|------|----------|------|-------------|
| `--reviews-dir` | Yes | path | Root directory containing `{condition}/` subdirs of ReviewResponse JSON files |
| `--output-csv` | Yes | path | Path to write per-run token CSV |
| `--output-summary` | Yes | path | Path to write per-group summary JSON |

### Output Files

**Per-run CSV** (`--output-csv`):
```
run_id,condition,language,trial,input_tokens,output_tokens,estimated_cost_usd,missing_data
python-1-v2,unconstrained,python,1,1842,743,0.0834,false
...
```

**Per-group summary JSON** (`--output-summary`):
Array of objects matching the ExperimentSummary schema (token fields only).

### Example
```bash
python3 analysis/token_analysis.py \
  --reviews-dir experiments/track1/reviews \
  --output-csv experiments/track1/reports/token-per-run.csv \
  --output-summary experiments/track1/reports/token-summary.json
```

---

## review/report.py — Report Generator

### Purpose
Aggregate RunMetrics files into ExperimentSummary tables and render Markdown
reports for Experiments A, B, and H.

### Invocation
```
python3 review/report.py \
  --metrics-dir PATH \
  --token-summary PATH \
  --output-dir PATH
```

### Arguments

| Flag | Required | Type | Description |
|------|----------|------|-------------|
| `--metrics-dir` | Yes | path | Directory containing RunMetrics JSON files |
| `--token-summary` | Yes | path | Per-group summary JSON from `token_analysis.py` |
| `--output-dir` | Yes | path | Directory to write Markdown reports |

### Output Files (under `--output-dir`)

| File | Content |
|------|---------|
| `experiment-a.md` | DDR/FPR summary table for unconstrained condition (Exp A) |
| `experiment-b.md` | DDR/FPR summary table for refactory-profile condition (Exp B) |
| `experiment-h.md` | Token cost analysis across all conditions (Exp H) |
| `comparison-table.md` | Combined A vs B comparison with absolute and relative differences |

### Example
```bash
python3 review/report.py \
  --metrics-dir experiments/track1/metrics \
  --token-summary experiments/track1/reports/token-summary.json \
  --output-dir experiments/track1/reports
```

---

## run-track1.sh — End-to-End Orchestrator

### Purpose
Run the full Track 1 pipeline (inject → review → score → analyse → report)
without interactive input.

### Invocation
```
bash run-track1.sh \
  [--data-branch BRANCH] \
  [--condition CONDITION] \
  [--model MODEL] \
  [--dry-run]
```

### Arguments

| Flag | Default | Description |
|------|---------|-------------|
| `--data-branch` | `data` | Git branch containing generated source code |
| `--condition` | `both` | `unconstrained`, `refactory-profile`, or `both` |
| `--model` | `claude-opus-4.6` | Anthropic model to use for reviews |
| `--dry-run` | false | Print commands without executing API calls |

### Behaviour
1. Reads `results/results.json` to identify target runs (Python + Rust, both passes).
2. For each target run: runs `bugs/inject.py` (skips if manifest already exists).
3. For each target run × condition: runs `review/harness.py` (skips if response already exists).
4. For each target run × condition: runs `review/score.py` (always re-scores).
5. Runs `analysis/token_analysis.py`.
6. Runs `review/report.py`.

Skipping existing artifacts ensures the pipeline is resumable after partial
failures without re-incurring API costs.

### Exit Codes
- 0: all steps succeeded (missing-data runs documented but not fatal)
- 1: argument error
- 2: critical failure (e.g., inject tool fails; cannot proceed)
