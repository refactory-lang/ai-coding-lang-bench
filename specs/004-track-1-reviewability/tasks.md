# Tasks: Track 1 — Reviewability Gap (Experiments A, B, H)

**Feature Branch**: `copilot/004-track-1-reviewability`  
**Spec**: `specs/004-track-1-reviewability/spec.md`  
**Plan**: `specs/004-track-1-reviewability/plan.md`  
**Created**: 2026-03-20  
**Status**: Ready for implementation

---

## Quick Reference

| Stat | Value |
|------|-------|
| Total tasks | 21 |
| US1 tasks (P1) | 8 (T005–T012) |
| US2 tasks (P2) | 2 (T013–T014) |
| US3 tasks (P3) | 2 (T015–T016) |
| Parallelisable tasks | 10 |
| Test tasks | 5 (T008, T010, T012, T016, T018) |
| Suggested MVP scope | Phase 3 complete (US1 end-to-end: inject → review → score) |

---

## Dependency Order

```
Phase 1 (Setup)
  |-> Phase 2 (Foundation: bug catalog)
        |-> Phase 3 (US1: injection + harness + scorer)
              |-> Phase 4 (US2: refactory-profile condition)  --+
              |-> Phase 5 (US3: token analysis)               --|
              |                                                  v
              +------------------------------> Phase 6 (Polish: reports + orchestration)
```

Within Phase 3 the internal execution order is:

```
T005[P], T006[P], T007  (parallel start: all three independent)
    T005+T006 -> T009
    T007      -> T008[P]     (inject tests; does not block T011)
    T007+T009 -> T011        (score.py; T008 does NOT need to complete first)
    T009      -> T010[P]     (harness tests; parallel with T011)
    T011      -> T012
```

---

## Phase 1: Setup

> **Goal**: Create the on-disk scaffold and repository configuration required by all subsequent phases.

- [ ] T001 Create experiments/track1/ directory scaffold with subdirectories: seeded/, manifests/, reviews/unconstrained/, reviews/refactory-profile/, metrics/, reports/
- [ ] T002 [P] Add `experiments/track1/seeded/` to .gitignore (seeded source lives on the data branch; all other track1/ subdirs are committed)

---

## Phase 2: Foundation — Bug Catalog

> **Goal**: Establish the pre-defined, deterministic bug catalog that all injection and scoring tasks depend on. Must be complete before any Phase 3 work begins.

- [ ] T003 Write bugs/catalog.json containing exactly 12 `BugDefinition` entries (6 Python + 6 Rust) using the schema in `specs/004-track-1-reviewability/data-model.md`

  **Bug IDs — Python**: `PY-OBO-LOG`, `PY-HASH-SEED`, `PY-STATUS-STAGE`, `PY-PARENT-NULL`, `PY-INDEX-FLUSH`, `PY-DIFF-BASE`  
  **Bug IDs — Rust**: `RS-OBO-LOG`, `RS-HASH-SEED`, `RS-STATUS-STAGE`, `RS-PARENT-NULL`, `RS-INDEX-FLUSH`, `RS-DIFF-BASE`

  Each entry must include `id`, `category`, `language`, `description`, `affected_commands`, `test_impact`, and `injection_strategy`. All bugs must be logic errors that survive `python3 -m py_compile` (Python) or `cargo check` (Rust) and do not trip all 30 v2 test cases (FR-002). Categories: `off-by-one`, `wrong-hash-seed`, `wrong-status`, `missing-parent`, `index-not-flushed`, `wrong-diff-base`.

  *Validation*: `python3 -c "import json; c=json.load(open('bugs/catalog.json')); assert len(c)==12; assert sum(1 for e in c if e['language']=='python')==6"` passes.

- [ ] T004 [P] Update bugs/README.md with: catalog purpose and scope (Track 1 Exp A/B), `BugDefinition` schema reference, how to add a new bug template, `inject.py` usage examples, and explanation of deterministic bug selection via PRNG seed

---

## Phase 3: User Story 1 — Bug Injection & Single-Pass Unconstrained Review (P1)

> **Story goal**: Inject exactly 3 seeded logic bugs into each of the 39 target MiniGit implementations (20 Python + 19 Rust), submit each seeded copy to a single-pass non-agentic Anthropic Claude review (unconstrained condition), and score each review to produce per-run DDR and FPR.
>
> **Independent test**: Inject one known bug into a single Python implementation, run the unconstrained reviewer, confirm the ReviewResponse JSON contains a `findings` list, and confirm `score.py` produces `ddr` in [0, 1].

- [ ] T005 [P] [US1] Create review/prompts/unconstrained.txt containing the reviewer system prompt: expert logic-error-only review, structured output format `**Finding N**: <file_path>, lines <start>–<end>` followed by one-sentence description; no fix suggestions; no style comments

- [ ] T006 [P] [US1] Create review/pricing.json mapping Anthropic model strings to per-1k-token USD prices; must include at minimum `claude-opus-4.6` (`input_per_1k: 0.015`, `output_per_1k: 0.075`) and `claude-sonnet-4-5` (`input_per_1k: 0.003`, `output_per_1k: 0.015`); update to current Anthropic pricing before running the experiment

- [ ] T007 [US1] Implement bugs/inject.py CLI per `specs/004-track-1-reviewability/contracts/cli-contracts.md`: copy source to output dir, load catalog, select 3 bugs via `--bugs` list or PRNG seed, apply `injection_strategy` transformations, verify compilation, write `BugManifest` JSON to `--manifest-path` (FR-001, FR-002, FR-008, FR-009)

  *Flags*: `--source-dir`, `--output-dir`, `--manifest-path`, `--language`, `--trial`, `[--bugs BUG_ID,BUG_ID,BUG_ID]`, `[--seed INT]`  
  *Constraints*: idempotent (re-run overwrites); exits 1 if fewer than 3 catalog entries match the language; manifest `bugs` array always has exactly 3 `BugInjection` elements with `bug_id`, `category`, `file_path`, `line_number`, `original_line`, `injected_line`

- [ ] T008 [US1] Write bugs/test_inject.py covering: (1) happy-path injection into minimal valid Python file produces manifest with 3 entries; (2) idempotency — running twice produces identical output; (3) determinism — same `--seed` always selects same 3 bugs; (4) compilation guard — catalog entry producing invalid syntax causes tool to error; (5) co-location edge case — two bugs targeting same line both recorded at correct `line_number`

  *Runner*: `python3 -m pytest bugs/test_inject.py -v`

- [ ] T009 [US1] Implement review/harness.py CLI per `specs/004-track-1-reviewability/contracts/cli-contracts.md`: read manifest for metadata, load condition prompt, concatenate source files alphabetically with `### filename` headers, call `anthropic.Anthropic().messages.create(temperature=0, no tools)`, parse `**Finding N**:` findings, look up pricing, write `ReviewResponse` JSON; retry policy: catch `APIStatusError` (5xx) and `RateLimitError`, backoff 2 s/4 s/8 s, on exhaustion write `missing_data: true` exit 2; terminal errors (`AuthenticationError`, `InvalidRequestError`) write `missing_data: true` exit 1 immediately (FR-003, FR-003a, FR-004, FR-008, FR-009)

  *Flags*: `--seeded-dir`, `--manifest-path`, `--output-path`, `--condition`, `[--model claude-opus-4.6]`, `[--max-tokens 4096]`, `[--api-key-env ANTHROPIC_API_KEY]`  
  *Output schema*: `ReviewResponse` per `data-model.md` — includes `run_id`, `condition`, `model`, `reviewed_at`, `input_tokens`, `output_tokens`, `finish_reason`, `price_per_1k_input_usd`, `price_per_1k_output_usd`, `estimated_cost_usd`, `raw_text`, `findings[]`, `missing_data`, `missing_data_reason`, `retry_count`

- [ ] T010 [US1] Write review/test_harness.py integration tests using a mocked `anthropic.Anthropic` client covering: (1) happy path — mock returns 2 findings → JSON written with `missing_data: false`, correct token counts; (2) rate-limit retry — mock raises `RateLimitError` twice then succeeds → `retry_count: 2`, `missing_data: false`; (3) exhausted retries — mock raises `APIStatusError` (5xx) 3× → `missing_data: true`, exit code 2; (4) auth error — mock raises `AuthenticationError` → `missing_data: true`, exit code 1, no retry attempted; (5) empty findings — mock returns review text with zero `**Finding N**:` blocks → `findings: []`, `missing_data: false`

  *Runner*: `python3 -m pytest review/test_harness.py -v`  
  *Note*: no real API calls; mock via `unittest.mock.patch`

- [ ] T011 [US1] Implement review/score.py CLI per `specs/004-track-1-reviewability/contracts/cli-contracts.md`: load `BugManifest` and `ReviewResponse`, apply location-based matching (`finding.file_path == bug.file_path AND |finding.line_start - bug.line_number| <= line_tolerance`, default 5), apply co-location rule (finding matching a shared window is TP for all bugs at that location), classify remaining findings as FP, compute `tp_count`, `fp_count`, `fn_count = total_bugs - tp_count`, `ddr = tp_count / total_bugs`, `fpr = fp_count / (fp_count + fn_count)` (0 when denominator is 0), copy token fields from `ReviewResponse`, write `RunMetrics` JSON; if `ReviewResponse.missing_data == true` write metrics with `missing_data: true`, `ddr: null`, `fpr: null` (FR-005, FR-008)

  *Flags*: `--manifest-path`, `--review-path`, `--output-path`, `[--line-tolerance 5]`  
  *Exit code*: always 0 (missing data is a valid outcome, not an error)  
  *Output path convention*: `experiments/track1/metrics/{lang}-{trial}-v2-{condition}.json`

- [ ] T012 [US1] Write review/test_score.py unit tests covering: (1) all 3 bugs detected — 3 matching findings → `ddr=1.0`, `fp_count=0`; (2) no findings — `ddr=0.0`, `fpr=0.0`; (3) partial detection — 1 of 3 bugs found, 2 FPs → `ddr≈0.333`, `fp_count=2`; (4) co-located bugs — 2 bugs at line 87; 1 finding at line 87 → both TPs, `tp_count=2`; (5) line tolerance pass — bug at line 87; finding at line 90; tolerance=5 → TP; (6) line tolerance exceeded — bug at line 87; finding at line 93; tolerance=5 → FP; (7) null `line_start` in finding — classified as FP; (8) missing data propagation — `ReviewResponse.missing_data=true` → `RunMetrics.ddr=null`, `RunMetrics.fpr=null`

  *Runner*: `python3 -m pytest review/test_score.py -v`

---

## Phase 4: User Story 2 — Constrained Python Review / Experiment B (P2)

> **Story goal**: Run the same seeded Python implementations through the review harness under the Refactory-profile ("Python-as-Rust") constraint and confirm the output is structurally identical to Experiment A, enabling direct DDR/FPR comparison.
>
> **Independent test**: Run the harness on one seeded Python implementation with `--condition refactory-profile` and confirm the ReviewResponse JSON schema matches Experiment A output exactly.

- [ ] T013 [P] [US2] Create review/prompts/refactory-profile.txt containing: Rust-constraint preamble (flag shared-state mutation without explicit tracking; flag file/resource handles not closed in finally/context-manager; flag index/key access without bounds check) prepended to the full unconstrained prompt from review/prompts/unconstrained.txt; output format must be identical to unconstrained (same `**Finding N**:` structure)

- [ ] T014 [US2] Add Experiment B condition test to review/test_harness.py: verify that invoking harness with `--condition refactory-profile` loads `review/prompts/refactory-profile.txt` (not unconstrained.txt), and that the resulting `ReviewResponse` JSON has identical field structure to an unconstrained response (enabling same scoring logic); confirm `condition` field is `"refactory-profile"` in output

  *Note*: Extend the existing test module from T010; no new file needed

---

## Phase 5: User Story 3 — Review Token Economics / Experiment H (P3)

> **Story goal**: Process all saved `ReviewResponse` files from Experiments A and B, extract token counts, compute per-run costs, aggregate by language × condition, and produce a cost-evidence report with zero missing runs in the summary.
>
> **Independent test**: Process the saved token logs from a single Experiment A review run and verify the summary output (total input tokens, output tokens, estimated cost) is computed correctly.

- [ ] T015 [P] [US3] Implement analysis/token_analysis.py CLI per `specs/004-track-1-reviewability/contracts/cli-contracts.md`: recursively scan `--reviews-dir` for `*.json` files (both `unconstrained/` and `refactory-profile/` subdirs), parse as `ReviewResponse`, extract `run_id`, `condition`, `language`, `trial`, `input_tokens`, `output_tokens`, `estimated_cost_usd`, `missing_data`, write per-run CSV to `--output-csv` and per-group summary JSON to `--output-summary`; aggregate groups by `(language, condition)` computing `n_runs`, `n_missing`, `mean`/`std` for token and cost fields, and sums (FR-006)

  *Flags*: `--reviews-dir`, `--output-csv`, `--output-summary`  
  *Expected output*: per-run CSV (one row per `ReviewResponse` file found) and per-group summary JSON. Per spec, Experiment A covers all 39 implementations (Python + Rust, unconstrained), and Experiment B covers only the 20 Python implementations (refactory-profile) — so the full CSV has 59 rows (20 + 19 + 20) and the summary has 3 populated groups: `python/unconstrained`, `python/refactory-profile`, `rust/unconstrained`. The `rust/refactory-profile` group may appear with `n_runs: 0` or be omitted; either is acceptable provided the tool handles an empty directory without error. *(Note: plan.md mentions 78 calls = 39 × 2 conditions, which would include Rust under Exp B; if the experiment scope is extended to Rust, this row count increases to 78 and all 4 groups are populated. The tool must handle both sizes without code changes.)*  
  *Stdlib only*: no external dependencies beyond `csv`, `json`, `statistics`, `pathlib`

- [ ] T016 [P] [US3] Write analysis/test_token_analysis.py covering: (1) happy path — 3 mock `ReviewResponse` files → CSV has 3 rows, summary means are correct; (2) missing data excluded from means — 1 missing + 2 valid → means over 2 only, `n_missing: 1`; (3) group aggregation — 2 languages × 2 conditions → 4 summary entries; (4) empty input — no JSON files → empty CSV header row, empty summary array

  *Runner*: `python3 -m pytest analysis/test_token_analysis.py -v`

---

## Phase 6: Polish & Cross-Cutting Concerns

> **Goal**: Reporting, end-to-end orchestration, and documentation sufficient for a new contributor to reproduce results without reading source code (SC-006).

- [ ] T017 [P] Implement review/report.py CLI per `specs/004-track-1-reviewability/contracts/cli-contracts.md`: aggregate `RunMetrics` files into `ExperimentSummary` tables and render four Markdown reports under `--output-dir` — `experiment-a.md` (DDR/FPR for unconstrained, both languages), `experiment-b.md` (DDR/FPR for refactory-profile, Python only), `experiment-h.md` (token cost analysis: per-group mean input tokens, output tokens, mean cost, total cost, absolute and % difference between conditions), `comparison-table.md` (side-by-side DDR, FPR, mean cost for all conditions — must show ≥ 2 languages and ≥ 2 conditions per SC-005); missing-data runs noted with "(N missing)" in each table; re-running on unchanged inputs produces identical output (FR-007)

  *Flags*: `--metrics-dir`, `--token-summary`, `--output-dir`

- [ ] T018 [P] Write review/test_report.py covering: (1) experiment-a.md renders correctly — 2 RunMetrics inputs (python, rust) → table has 2 language rows with correct DDR values; (2) missing data noted in report — 1 missing run → "(1 missing)" appears in the relevant table; (3) experiment-h.md cost comparison — unconstrained $0.08/run, refactory $0.09/run → delta column shows +$0.01 (+12.5%); (4) comparison-table.md columns — `Language`, `Condition`, `DDR`, `FPR`, `Mean Cost (USD)` all present

  *Runner*: `python3 -m pytest review/test_report.py -v`

- [ ] T019 Implement run-track1.sh end-to-end orchestrator per `specs/004-track-1-reviewability/contracts/cli-contracts.md`: read `results/results.json` to build target list (Python + Rust runs where both `v1_pass` and `v2_pass` are true); for each run call `bugs/inject.py` (skip if manifest at `experiments/track1/manifests/{run_id}.json` already exists); for each run × condition call `review/harness.py` (skip if response at `experiments/track1/reviews/{condition}/{run_id}.json` already exists); for each run × condition call `review/score.py` (always re-score — deterministic); call `analysis/token_analysis.py`; call `review/report.py`; print summary: `N runs seeded, N reviews completed (N missing), reports written to experiments/track1/reports/`; `--dry-run` flag prints all commands without executing API calls; exit codes: 0 success, 1 argument error, 2 inject failure (FR-008)

  *Flags*: `[--data-branch data]`, `[--condition both|unconstrained|refactory-profile]`, `[--model claude-opus-4.6]`, `[--dry-run]`  
  *Skip logic*: critical for resumability — prevents re-incurring API costs after partial failure (FR-009, SC-002)

- [ ] T020 Write specs/004-track-1-reviewability/quickstart.md step-by-step reproduction guide covering: (1) prerequisites (Python 3.9+, `pip install anthropic`, `ANTHROPIC_API_KEY` env var, access to `data` branch); (2) checking out the `data` branch and verifying the 39-implementation source pool; (3) dry-run verification: `bash run-track1.sh --dry-run`; (4) running Experiment A: `bash run-track1.sh --condition unconstrained`; (5) running Experiment B: `bash run-track1.sh --condition refactory-profile`; (6) running Experiment H token analysis standalone; (7) where to find reports under `experiments/track1/reports/`; (8) how to re-score without re-calling the API (delete only metrics/ files; leave reviews/ intact)

  *Acceptance*: a reviewer unfamiliar with the codebase can execute the pipeline following this guide without consulting source code (SC-006)

- [ ] T021 Update EXPERIMENTS.md with a "Running Track 1" section under the Track 1 heading: include the single `run-track1.sh` command for end-to-end execution, link to `specs/004-track-1-reviewability/quickstart.md`, note expected runtime (~5 min for injection + scoring, ~15–20 min for 78 API calls) and estimated API cost (~$1.10 at claude-opus-4.6 2026-03 pricing)

---

## Dependency Graph

```
T001 --+
T002 --+  (parallel)
       |
       v
T003 --+
T004 --+  (parallel; T004 soft-depends on T003 for content)
       |
       v
T005[P] --+
T006[P] --+  (parallel start; all independent)
T007    --+
       |
       +-- T008[P]  (after T007; inject tests)
       +-- T009     (after T005+T006; harness impl)
              |
              +-- T010[P]  (after T009; harness tests)
              +-- T011     (after T007+T009; scorer — T008 not required)
                     |
                     +-- T012
                            |
              +-------------+
              |             |
              v             v
           T013[P]      T015[P]
           T014         T016[P]
              |             |
              +------+------+
                     |
                     v
                  T017[P]
                  T018[P]
                     |
                     v
                   T019
                   T020
                   T021
```

**Phase cross-dependencies**:
- T013 (refactory-profile prompt) has no code dependencies and can be authored in parallel with Phase 3 work, but logically belongs to US2.
- T015 (token_analysis.py) only needs the `ReviewResponse` JSON schema (defined by T009); it can be developed in parallel with Phase 4 once T009 is complete.

---

## Parallel Execution Examples

### US1 (Phase 3) — Three-stream start
```
Stream A: T005 -> T009 -> T010
Stream B: T006 -> T009 (join with A)
Stream C: T007 -> T008
          T007 -> T011 (after T009 also ready)
                T011 -> T012
```
T008 (inject tests) and T011 (score.py) can both start once their respective direct
dependencies are met. T011 requires T007 + T009; it does NOT need T008 to complete
first. T010 requires only T009.

### US2 + US3 (Phases 4–5) — Post-US1 parallel
```
Stream A: T013 → T014
Stream B: T015 → T016
(join) → T017, T018
```

### Phase 6 (Polish)
```
T017[P] and T018[P] in parallel
(join) → T019 → T020 → T021
```

---

## Implementation Strategy

**MVP scope (Phase 3 only)**: Complete T001–T012 for a fully working inject → review → score pipeline. This satisfies US1, allows spot-checking the reviewer output on real implementations, and de-risks the API integration before committing to all 78 calls.

**Incremental delivery**:
1. T001–T004: Bootstrap (no API required; no Python tooling needed; fast)
2. T005–T007: Create inert artefacts and injection tool (no API required; testable with `--dry-run`)
3. T008–T010: Tests catch regressions before integration
4. T011–T012: Scorer completes the loop; US1 independently testable
5. T013–T014: US2 requires only one new file + one test extension
6. T015–T016: US3 is purely analytical; can be developed before Exp A/B data exists
7. T017–T021: Reports and orchestration are the final integration layer

**Cost gating**: Run `bash run-track1.sh --dry-run` after T019 to validate the full command sequence before committing to the ~$1.10 API spend.

---

## Test Execution Summary

| File | Tool Under Test | Runner | Phase |
|------|----------------|--------|-------|
| `bugs/test_inject.py` | `bugs/inject.py` | `python3 -m pytest bugs/test_inject.py -v` | Phase 3 |
| `review/test_harness.py` | `review/harness.py` | `python3 -m pytest review/test_harness.py -v` | Phase 3–4 |
| `review/test_score.py` | `review/score.py` | `python3 -m pytest review/test_score.py -v` | Phase 3 |
| `analysis/test_token_analysis.py` | `analysis/token_analysis.py` | `python3 -m pytest analysis/test_token_analysis.py -v` | Phase 5 |
| `review/test_report.py` | `review/report.py` | `python3 -m pytest review/test_report.py -v` | Phase 6 |

All tests use `stdlib` + `pytest` only. No real API calls — Anthropic client mocked via `unittest.mock.patch`.

Full suite: `python3 -m pytest bugs/ review/ analysis/ -v`

---

## Completion Criteria

All tasks complete when:

- [ ] `python3 -m pytest bugs/ review/ analysis/ -v` passes (all unit + integration tests, zero skipped)
- [ ] `bash run-track1.sh --dry-run` exits 0 and prints all 39 inject + 78 review + 78 score + 1 analyse + 1 report command lines
- [ ] `bugs/catalog.json` has exactly 12 entries — `python3 -c "import json; c=json.load(open('bugs/catalog.json')); assert len(c)==12"` passes
- [ ] All five Python tool scripts accept `--help` and exit 0: `bugs/inject.py`, `review/harness.py`, `review/score.py`, `analysis/token_analysis.py`, `review/report.py`
- [ ] `specs/004-track-1-reviewability/quickstart.md` exists and has been reviewed by at least one other contributor
- [ ] Spec success criteria SC-001 through SC-006 are each verifiable from the produced artifacts
- [ ] `experiments/track1/reports/comparison-table.md` shows ≥ 2 languages × ≥ 2 conditions with DDR, FPR, and mean cost columns (SC-005)
