# Tasks: Track 1 — Reviewability Gap (Experiments A, B, H)

**Feature Branch**: `copilot/004-track-1-reviewability`  
**Plan**: `specs/004-track-1-reviewability/plan.md`  
**Created**: 2026-03-20  
**Status**: Ready for implementation

---

## Dependency Order

```
Phase A → Phase B → Phase C → Phase D (parallel)
                               Phase E (parallel) → Phase F
```

All tasks within a phase are independent unless noted with "depends on".

---

## Phase A: Bug Catalog & Injection

### TASK-A1 — Write bug catalog JSON

**File**: `bugs/catalog.json`  
**Description**: Create the pre-defined bug catalog with 6 logic-error templates for Python and 6 for Rust (12 entries total). Each entry follows the `BugDefinition` schema in `data-model.md`.

**Bug IDs (Python)**: `PY-OBO-LOG`, `PY-HASH-SEED`, `PY-STATUS-STAGE`, `PY-PARENT-NULL`, `PY-INDEX-FLUSH`, `PY-DIFF-BASE`  
**Bug IDs (Rust)**: `RS-OBO-LOG`, `RS-HASH-SEED`, `RS-STATUS-STAGE`, `RS-PARENT-NULL`, `RS-INDEX-FLUSH`, `RS-DIFF-BASE`

Each entry must include:
- `id`, `category`, `language`, `description`
- `affected_commands` (MiniGit commands impacted)
- `test_impact` (which of the 30 v2 tests fail/pass after injection)
- `injection_strategy` (precise, unambiguous transformation description)

**Acceptance**: `python3 -c "import json; c=json.load(open('bugs/catalog.json')); assert len(c)==12"` passes.

---

### TASK-A2 — Implement bug injection tool

**File**: `bugs/inject.py`  
**Description**: Implement the `bugs/inject.py` CLI tool per the contract in `contracts/cli-contracts.md`.

**Requirements to satisfy**: FR-001, FR-002, FR-008, FR-009

**Core logic**:
1. Copy `--source-dir` to `--output-dir` (overwrite if exists).
2. Load `bugs/catalog.json`, filter by `--language`.
3. Select 3 bugs: use `--bugs` list if provided, otherwise use PRNG seeded with `--seed` (default: trial number) to select 3 non-repeating entries.
4. For each selected bug, apply the `injection_strategy` transformation to the relevant file.
5. Verify compilation: run `python3 -m py_compile *.py` (Python) or `cargo check` (Rust); abort and report error if it fails.
6. Write `BugManifest` JSON to `--manifest-path`.

**Acceptance**:
- Running on `generated/minigit-python-{N}-v2` produces a manifest with exactly 3 entries and a seeded copy that compiles.
- Running twice with same args produces identical manifest and seeded copy (idempotent).
- Running with an unknown language exits with code 1 and a clear error message.

---

### TASK-A3 — Write inject.py unit tests

**File**: `bugs/test_inject.py`  
**Depends on**: TASK-A1, TASK-A2  
**Description**: Unit tests for the injection tool covering:

1. **Happy path**: inject into a minimal valid Python file → manifest has 3 entries with correct metadata.
2. **Idempotency**: running twice produces identical output.
3. **Determinism**: same `--seed` always selects same 3 bugs.
4. **Compilation check**: injecting a bug that produces invalid Python syntax causes the tool to error (guard for future catalog mistakes).
5. **Co-location edge case**: if two selected bugs target the same line, both are recorded in the manifest at the same `line_number`.

**Acceptance**: `python3 -m pytest bugs/test_inject.py -v` passes all tests.

---

### TASK-A4 — Update bugs/README.md

**File**: `bugs/README.md`  
**Depends on**: TASK-A1, TASK-A2  
**Description**: Replace the one-line placeholder with a document covering:
- Purpose and scope (Track 1 Experiment A/B)
- Catalog format (`BugDefinition` schema reference)
- How to add a new bug template
- `inject.py` usage examples
- How bug selection is deterministic

---

## Phase B: Review Harness

### TASK-B1 — Write reviewer prompt templates

**Files**: `review/prompts/unconstrained.txt`, `review/prompts/refactory-profile.txt`  
**Description**: Create the two system prompt files per the design in `plan.md` (Phase 1 → Prompt Design section).

**unconstrained.txt**: instructs Claude to review for logic errors only, output structured findings in the exact format `**Finding N**: <file_path>, lines <start>–<end>` followed by a one-sentence description.

**refactory-profile.txt**: prepends the Rust-constraint preamble (flag shared-state mutation, unclosed resources, unchecked index access) then appends the unconstrained instructions.

**Acceptance**: Both files exist, are valid UTF-8, and contain the `**Finding N**:` output format string.

---

### TASK-B2 — Write pricing config

**File**: `review/pricing.json`  
**Description**: Create a JSON map of Anthropic model strings to per-1k-token prices (USD). Must include at minimum `claude-opus-4.6` and `claude-sonnet-4-5`. Values taken from published Anthropic pricing at experiment time.

```json
{
  "claude-opus-4.6":   { "input_per_1k": 0.015, "output_per_1k": 0.075 },
  "claude-sonnet-4-5": { "input_per_1k": 0.003, "output_per_1k": 0.015 }
}
```

**Note**: Update these values to match current Anthropic pricing when the experiment is run. The model key must match exactly the string passed to `--model`.

---

### TASK-B3 — Implement review harness

**File**: `review/harness.py`  
**Depends on**: TASK-B1, TASK-B2  
**Description**: Implement the `review/harness.py` CLI tool per the contract in `contracts/cli-contracts.md`.

**Requirements to satisfy**: FR-003, FR-003a, FR-004, FR-008, FR-009

**Core logic**:
1. Read `--manifest-path` to extract `run_id`, `language`, `trial`.
2. Load the prompt template for `--condition`.
3. Collect all source files from `--seeded-dir` in alphabetical order; concatenate with `### {filename}` headers as the user prompt.
4. Call `anthropic.Anthropic().messages.create(model=..., system=..., messages=[...], max_tokens=..., temperature=0)` — **no `tools` parameter**.
5. Parse the response text into a list of `ReviewFinding` objects using the `**Finding N**:` format.
6. Look up pricing from `review/pricing.json` for the model; compute `estimated_cost_usd`.
7. Write `ReviewResponse` JSON to `--output-path`.
8. Retry policy: catch `anthropic.APIStatusError` (status >= 500) and `anthropic.RateLimitError`; wait 2 s, 4 s, 8 s before retries 2, 3; on exhaustion write response with `missing_data: true` and exit code 2.
9. Terminal errors (`AuthenticationError`, `InvalidRequestError`): write `missing_data: true` and exit code 1 immediately.

**Acceptance**:
- With a valid API key, running on a seeded Python implementation produces a ReviewResponse JSON with `missing_data: false` and at least one field in `findings` (empty list is valid).
- Running with `--condition refactory-profile` on the same input produces an identically-structured JSON.
- Running with an invalid API key exits with code 1 and writes a `missing_data: true` response.

---

### TASK-B4 — Write harness integration test

**File**: `review/test_harness.py`  
**Depends on**: TASK-B3  
**Description**: Integration tests using a mocked Anthropic client:

1. **Happy path**: mock returns a response with 2 findings → JSON written with `missing_data: false`, `findings` has 2 entries, `input_tokens` matches mock usage.
2. **Rate limit retry**: mock raises `RateLimitError` twice then succeeds → `retry_count: 2`, `missing_data: false`.
3. **Exhausted retries**: mock raises `APIStatusError` 3× → `missing_data: true`, exit code 2.
4. **Auth error**: mock raises `AuthenticationError` → `missing_data: true`, exit code 1, no retry.
5. **Refactory-profile condition**: running with `refactory-profile` loads the correct prompt file.

**Acceptance**: `python3 -m pytest review/test_harness.py -v` passes all tests.

---

## Phase C: Scoring Engine

### TASK-C1 — Implement scoring tool

**File**: `review/score.py`  
**Depends on**: TASK-A2, TASK-B3  
**Description**: Implement `review/score.py` per the contract in `contracts/cli-contracts.md`.

**Requirements to satisfy**: FR-005, FR-008

**Core logic**:
1. Load `BugManifest` and `ReviewResponse` from JSON files.
2. For each injected bug `B`, scan all findings: a finding is a TP for `B` if `finding.file_path == B.file_path AND |finding.line_start - B.line_number| <= line_tolerance`.
3. Co-location rule: if multiple bugs share the same `(file_path, line_number)`, a finding that matches the location is a TP for **every** such bug.
4. Any finding not classified as TP for any bug is a FP.
5. Compute `tp_count`, `fp_count`, `fn_count = total_bugs - tp_count`, `ddr`, `fpr`.
6. Copy token counts and cost from `ReviewResponse`.
7. Write `RunMetrics` JSON to `--output-path`.
8. If `ReviewResponse.missing_data == true`: write metrics with `missing_data: true`, `ddr: null`, `fpr: null`.

**Acceptance**:
- Re-running on unchanged artifacts produces identical output.
- `ddr` is always in [0, 1] (or null for missing data).
- Zero findings → `ddr: 0.0`, `fpr: 0.0`.

---

### TASK-C2 — Write score.py unit tests

**File**: `review/test_score.py`  
**Depends on**: TASK-C1  
**Description**: Unit tests for the scoring algorithm:

1. **All bugs detected**: 3 findings matching all 3 bugs → `ddr=1.0`, `fp_count=0`.
2. **No bugs detected**: 0 findings → `ddr=0.0`, `fp_count=0`.
3. **Partial detection**: 1 of 3 bugs found, 2 FPs → `ddr=0.333`, `fp_count=2`.
4. **Co-located bugs**: 2 bugs at line 87; 1 finding at line 87 → both are TPs, `tp_count=2`.
5. **Line tolerance**: bug at line 87; finding at line 90; tolerance=5 → TP.
6. **Line tolerance exceeded**: bug at line 87; finding at line 93; tolerance=5 → FP.
7. **Null line_start in finding**: finding has no line number → FP (cannot match any bug).
8. **Missing data propagation**: `ReviewResponse.missing_data=true` → `RunMetrics.ddr=null`.

**Acceptance**: `python3 -m pytest review/test_score.py -v` passes all tests.

---

## Phase D: Token Analysis (Experiment H)

*Can be developed in parallel with Phase E once Phase C is complete.*

### TASK-D1 — Implement token analysis tool

**File**: `analysis/token_analysis.py`  
**Depends on**: TASK-B3 (ReviewResponse schema)  
**Description**: Implement `analysis/token_analysis.py` per the contract in `contracts/cli-contracts.md`.

**Requirements to satisfy**: FR-006

**Core logic**:
1. Recursively scan `--reviews-dir` for all `*.json` files; parse each as `ReviewResponse`.
2. Extract `run_id`, `condition`, `language`, `trial`, `input_tokens`, `output_tokens`, `estimated_cost_usd`, `missing_data`.
3. Write per-run CSV to `--output-csv`.
4. Aggregate by `(language, condition)`: compute `n_runs`, `n_missing`, `mean`/`std` for `input_tokens`, `output_tokens`, `estimated_cost_usd`; sum totals.
5. Write per-group summary JSON array to `--output-summary`.

**Acceptance**:
- Running on the full `experiments/track1/reviews/` directory produces a CSV with exactly `n_runs` rows (39 × 2 conditions = 78 rows).
- Summary JSON has 4 entries: `python/unconstrained`, `python/refactory-profile`, `rust/unconstrained`, `rust/refactory-profile`.
- `n_missing + n_valid = n_runs` for each group.

---

### TASK-D2 — Write token analysis unit tests

**File**: `analysis/test_token_analysis.py`  
**Depends on**: TASK-D1  
**Description**:

1. **Happy path**: 3 mock ReviewResponse files → CSV has 3 rows, summary has correct means.
2. **Missing data excluded from means**: 1 missing + 2 valid → means computed over 2 only, `n_missing: 1`.
3. **Group aggregation**: reviews from 2 languages × 2 conditions → 4 summary rows.
4. **Empty input**: no JSON files → empty CSV, empty summary array.

**Acceptance**: `python3 -m pytest analysis/test_token_analysis.py -v` passes.

---

## Phase E: Report Generator

*Can be developed in parallel with Phase D once Phase C is complete.*

### TASK-E1 — Implement report generator

**File**: `review/report.py`  
**Depends on**: TASK-C1, TASK-D1  
**Description**: Implement `review/report.py` per the contract in `contracts/cli-contracts.md`.

**Requirements to satisfy**: FR-007

**Outputs**:

- **`experiment-a.md`**: Table of DDR and FPR per language for `unconstrained` condition; one row per language, showing mean ± std; n_runs; n_missing.
- **`experiment-b.md`**: Same table for `refactory-profile` condition (Python only, since Exp B targets Python).
- **`experiment-h.md`**: Token cost table — per language × condition: mean input tokens, mean output tokens, mean cost USD, total cost USD. Includes absolute and % differences between unconstrained and refactory-profile.
- **`comparison-table.md`**: Side-by-side DDR, FPR, and mean cost for all conditions (SC-005).

**Acceptance**:
- `comparison-table.md` contains at least 2 language rows and 2 condition columns.
- All four files are valid Markdown (no syntax errors).
- Re-running generates identical output from identical input.

---

### TASK-E2 — Write report generator unit tests

**File**: `review/test_report.py`  
**Depends on**: TASK-E1  
**Description**:

1. **experiment-a.md renders correctly**: 2 RunMetrics files (python, rust) → table has 2 rows with correct DDR values.
2. **Missing data in report**: 1 missing run → noted in report with "(N missing)" count.
3. **experiment-h.md cost comparison**: unconstrained costs $0.08/run, refactory $0.09/run → Δ shows +$0.01 (+12.5%).
4. **comparison-table.md columns**: at least `Language`, `Condition`, `DDR`, `FPR`, `Mean Cost` columns present.

**Acceptance**: `python3 -m pytest review/test_report.py -v` passes.

---

## Phase F: Orchestration & Documentation

### TASK-F1 — Implement end-to-end orchestrator

**File**: `run-track1.sh`  
**Depends on**: All Phase A–E tasks  
**Description**: Implement the orchestrator per the contract in `contracts/cli-contracts.md`.

**Core logic**:
1. Parse `--data-branch`, `--condition`, `--model`, `--dry-run` flags.
2. Read `results/results.json` to build the list of target runs (Python + Rust, `v1_pass=true` AND `v2_pass=true`).
3. For each run: call `bugs/inject.py` (skip if manifest exists at `experiments/track1/manifests/{run_id}.json`).
4. For each run × condition: call `review/harness.py` (skip if review exists at `experiments/track1/reviews/{condition}/{run_id}.json`).
5. For each run × condition: call `review/score.py` (always re-score; deterministic).
6. Call `analysis/token_analysis.py`.
7. Call `review/report.py`.
8. Print a summary: `N runs seeded, N reviews completed (N missing), reports written to experiments/track1/reports/`.

**Skip logic**: avoids re-incurring API costs when resuming after partial failure (FR-009 and SC-002).

**Acceptance**:
- `bash run-track1.sh --dry-run` prints all commands without executing API calls.
- `bash run-track1.sh --condition unconstrained` processes only Experiment A.
- Script exits 0 when all runs succeed; exits 2 if any inject step fails; exits 0 with a warning if some review runs are missing data.

---

### TASK-F2 — Write quickstart guide

**File**: `specs/004-track-1-reviewability/quickstart.md`  
**Depends on**: TASK-F1  
**Description**: Step-by-step reproduction guide covering:

1. Prerequisites (Python 3.9+, `anthropic` Python package, `ANTHROPIC_API_KEY`, access to `data` branch).
2. How to check out the `data` branch and verify the source pool.
3. Running the dry-run to confirm setup.
4. Running Experiment A: `bash run-track1.sh --condition unconstrained`.
5. Running Experiment B: `bash run-track1.sh --condition refactory-profile`.
6. Running Experiment H token analysis: `python3 analysis/token_analysis.py ...`.
7. Where to find the reports.
8. How to re-score without re-calling the API.

**Acceptance**: A reviewer unfamiliar with the codebase can follow the guide without consulting source code. No undocumented steps.

---

### TASK-F3 — Update EXPERIMENTS.md with Track 1 pipeline command

**File**: `EXPERIMENTS.md`  
**Depends on**: TASK-F1, TASK-F2  
**Description**: Add a "Running Track 1" section to `EXPERIMENTS.md` under the Track 1 heading. Include:
- The single `run-track1.sh` command for end-to-end execution
- A link to `specs/004-track-1-reviewability/quickstart.md` for full instructions
- A brief note on expected runtime and API cost

---

### TASK-F4 — Add .gitignore entries

**File**: `.gitignore`  
**Description**: Add entries to ensure experiment outputs are not accidentally committed to the feature branch:
```
# Track 1 experiment outputs (data branch or gitignored)
experiments/track1/seeded/
```
Note: `manifests/`, `reviews/`, `metrics/`, and `reports/` are small JSON/Markdown files intended to be committed as experimental outputs.

---

## Test Execution Summary

| Test File | Tool Under Test | Runner |
|-----------|----------------|--------|
| `bugs/test_inject.py` | `bugs/inject.py` | `python3 -m pytest bugs/test_inject.py` |
| `review/test_harness.py` | `review/harness.py` | `python3 -m pytest review/test_harness.py` |
| `review/test_score.py` | `review/score.py` | `python3 -m pytest review/test_score.py` |
| `analysis/test_token_analysis.py` | `analysis/token_analysis.py` | `python3 -m pytest analysis/test_token_analysis.py` |
| `review/test_report.py` | `review/report.py` | `python3 -m pytest review/test_report.py` |

All tests use stdlib + pytest only (no API calls; Anthropic client mocked via `unittest.mock`).

---

## Completion Criteria

All tasks complete when:
- [ ] `python3 -m pytest bugs/ review/ analysis/ -v` passes (all unit + integration tests)
- [ ] `bash run-track1.sh --dry-run` exits 0 and prints all expected command lines
- [ ] `bugs/catalog.json` has 12 entries (6 Python + 6 Rust)
- [ ] `specs/004-track-1-reviewability/quickstart.md` exists and is reviewed by one other contributor
- [ ] All five tool scripts accept `--help` and exit 0
- [ ] Spec acceptance criteria SC-001 through SC-006 are verifiable from the artifacts
