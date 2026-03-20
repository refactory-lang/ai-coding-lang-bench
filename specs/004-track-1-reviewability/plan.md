# Implementation Plan: Track 1 — Reviewability Gap (Experiments A, B, H)

**Feature Branch**: `copilot/004-track-1-reviewability`  
**Spec**: `specs/004-track-1-reviewability/spec.md`  
**Created**: 2026-03-20  
**Status**: Design complete — ready for task generation

---

## Technical Context

| Item | Value |
|------|-------|
| Languages targeted | Python (20 runs), Rust (19 runs) — 39 total implementations |
| Bug catalog size | 6 templates per language (3 drawn per run) |
| API provider | Anthropic Claude (default model: `claude-opus-4.6`, configurable) |
| Conditions | `unconstrained` (Exp A), `refactory-profile` (Exp B) |
| Total review API calls | 39 × 2 conditions = **78 calls** |
| Estimated token cost | ~$1.10 total at 2026-03 claude-opus pricing |
| Retry policy | 3× exponential backoff (2 s / 4 s / 8 s) |
| Tooling language | Python 3.9+ (stdlib + `anthropic` SDK) |
| Orchestration | Bash (`run-track1.sh`) |
| Intermediate storage | JSON files on disk under `experiments/track1/` |
| Source pool | `data` branch — `generated/minigit-{lang}-{trial}-v2/` |
| Seeded copies | `experiments/track1/seeded/` (committed to `data` branch) |

All unknowns resolved. See `specs/004-track-1-reviewability/research.md`.

---

## Constitution Check

The project constitution (`/.specify/memory/constitution.md`) contains only
placeholder template text — no ratified principles have been established. The
following project-level conventions have been extracted from the existing
codebase instead and are treated as implicit standards:

| Convention | Source | Compliance |
|-----------|--------|-----------|
| CLI tools accept args, write to files, not stdout | `benchmark.rb`, `report.rb` | ✅ All Track 1 tools follow this pattern |
| JSON for all structured intermediate data | `results/results.json`, log files | ✅ All artifacts are JSON |
| Runnable without interactive input | FR-008 and benchmark.rb design | ✅ All tools accept `--help` and CLI flags only |
| Output persisted for reproducibility | `logs/` in data branch; FR-009 | ✅ All intermediate outputs saved before consuming |
| Python 3.x for scripting | `analysis/`, `plot.py` | ✅ All new tooling is Python 3.9+ |
| Markdown for human-readable reports | `results/report.md` | ✅ Report generator outputs Markdown |

**Gate Result: PASS** — No constitution violations identified.

---

## Phase 0: Research Summary

Research complete. See `specs/004-track-1-reviewability/research.md` for full
detail. Key decisions:

1. **Target pool**: 39 implementations (20 Python + 19 Rust), v2 only.
2. **Bug catalog**: 6 deterministic logic-error templates per language;
   3 drawn per run by PRNG seed = trial number. All bugs survive compilation
   and do not trip all 30 v2 tests.
3. **API integration**: Anthropic Python SDK, single `messages.create` call,
   `temperature=0`, no `tools`, `max_tokens=4096`.
4. **Retry**: SDK-level 5xx/RateLimitError → 3× exponential backoff (2/4/8 s);
   terminal errors (auth, invalid request) → mark as missing data immediately.
5. **Scoring**: Location-based matching (file + line ±5); co-located bugs each
   scored independently against the shared window.
6. **Refactory profile**: Additional system-prompt segment instructing the
   reviewer to apply Rust ownership/safety norms when reviewing Python.
7. **Token cost**: ~$1.10 estimated for all 78 review calls.

---

## Phase 1: Design & Contracts

### Data Model

See `specs/004-track-1-reviewability/data-model.md` for full schemas.

**Core entities (5):**

| Entity | File | Role |
|--------|------|------|
| `BugDefinition` | `bugs/catalog.json` | Catalog of injectable bug templates |
| `BugManifest` | `experiments/track1/manifests/*.json` | Per-run record of injected bugs |
| `ReviewResponse` | `experiments/track1/reviews/{condition}/*.json` | Raw API response + parsed findings |
| `RunMetrics` | `experiments/track1/metrics/*.json` | Per-run DDR, FPR, token counts |
| `ExperimentSummary` | `experiments/track1/reports/*.json` | Aggregated stats per language × condition |

**Artifact pipeline:**
```
BugDefinition catalog
    └─▶ [inject.py] ──▶ BugManifest + seeded source
                             └─▶ [harness.py] ──▶ ReviewResponse
                                  └─▶ [score.py] ──▶ RunMetrics
                                       └─▶ [report.py] ──▶ ExperimentSummary
                              [token_analysis.py] ──▶ cost CSVs + summary
```

### CLI Contracts

See `specs/004-track-1-reviewability/contracts/cli-contracts.md`.

**Five tools + one orchestrator:**

| Tool | Purpose |
|------|---------|
| `bugs/inject.py` | Seed exactly 3 bugs; write seeded copy + manifest |
| `review/harness.py` | Call Anthropic API; write ReviewResponse JSON |
| `review/score.py` | Compare manifest vs. response; write RunMetrics JSON |
| `analysis/token_analysis.py` | Aggregate token/cost data from all responses |
| `review/report.py` | Generate Markdown reports (Exp A, B, H + comparison) |
| `run-track1.sh` | End-to-end orchestrator; resumable (skips existing artifacts) |

### Prompt Design

**Unconstrained system prompt** (`review/prompts/unconstrained.txt`):
```
You are an expert code reviewer. Review the provided MiniGit implementation
for logic errors only. For each issue found, output a structured finding in
this exact format:

**Finding N**: <file_path>, lines <start>–<end>
<one-sentence description of the logic error>

Output only findings. Do not suggest fixes. Do not comment on style.
```

**Refactory-profile system prompt** (`review/prompts/refactory-profile.txt`):
Prepends to the unconstrained prompt:
```
You are reviewing Python code under Rust-like correctness constraints.
Flag any: (1) mutation of shared state without explicit tracking,
(2) file or resource handle not closed in a finally block or context manager,
(3) index or key access without bounds/key existence check.
In addition to these, also flag all logic errors as described below.
```

**Pricing config** (`review/pricing.json`):
```json
{
  "claude-opus-4.6": { "input_per_1k": 0.015, "output_per_1k": 0.075 },
  "claude-sonnet-4-5": { "input_per_1k": 0.003, "output_per_1k": 0.015 }
}
```

### Directory Structure

```
bugs/
  catalog.json              # Bug template catalog
  inject.py                 # Bug injection CLI tool
  README.md                 # (exists) Extended with catalog docs
review/
  harness.py                # Review API harness
  score.py                  # Scoring tool
  report.py                 # Report generator
  prompts/
    unconstrained.txt       # Reviewer system prompt (unconstrained)
    refactory-profile.txt   # Reviewer system prompt (refactory-profile)
  pricing.json              # Model pricing config
analysis/
  token_analysis.py         # Token/cost aggregation tool
  README.md                 # (exists) Extended with usage docs
experiments/
  track1/
    seeded/                 # Seeded implementations (data branch)
    manifests/              # BugManifest JSON files
    reviews/
      unconstrained/        # ReviewResponse JSON (Exp A)
      refactory-profile/    # ReviewResponse JSON (Exp B)
    metrics/                # RunMetrics JSON files
    reports/                # Markdown + JSON summaries
run-track1.sh               # End-to-end orchestrator
specs/004-track-1-reviewability/
  spec.md                   # (exists)
  plan.md                   # (this file)
  tasks.md                  # Task list
  research.md               # Research findings
  data-model.md             # Data model
  contracts/
    cli-contracts.md        # CLI tool contracts
```

---

## Implementation Phases

### Phase A: Foundation (Bug Catalog + Injection)

**Goal**: A deterministic, reproducible bug injection tool that produces
compilable seeded implementations and machine-readable manifests.

**Deliverables:**
- `bugs/catalog.json` — 6 bug templates per language (12 total)
- `bugs/inject.py` — injection CLI (FR-001, FR-002, FR-008, FR-009)
- Unit tests for injection logic
- Updated `bugs/README.md`

**Acceptance gate:** Running `bugs/inject.py` on any of the 39 target
implementations produces a manifest with exactly 3 bugs, the seeded copy
passes `python3 -m py_compile` (Python) or `cargo check` (Rust), and re-running
produces the same output.

**Effort estimate:** 3–4 days

---

### Phase B: Review Harness (Anthropic Integration)

**Goal**: A non-agentic single-pass reviewer that persists raw API responses
and handles failures gracefully.

**Deliverables:**
- `review/prompts/unconstrained.txt`
- `review/prompts/refactory-profile.txt`
- `review/pricing.json`
- `review/harness.py` — API harness with retry (FR-003, FR-003a, FR-004,
  FR-008, FR-009)
- Integration test against a single seeded implementation (mocked API key)

**Acceptance gate:** Running `harness.py` on one seeded Python implementation
(unconstrained) produces a ReviewResponse JSON with `findings` list, correct
token counts, and `missing_data: false`. Running with `--condition
refactory-profile` produces an identically-structured response.

**Effort estimate:** 2–3 days

---

### Phase C: Scoring Engine

**Goal**: A deterministic scorer that classifies findings against the manifest
and produces per-run DDR/FPR.

**Deliverables:**
- `review/score.py` — scoring CLI (FR-005, FR-008)
- Unit tests for the scoring algorithm (TP/FP/co-location cases)

**Acceptance gate:** Re-running `score.py` on saved artifacts gives identical
output. Co-located bug test passes: two bugs at line 87 → one finding at line
87 → both scored as TP.

**Effort estimate:** 1–2 days

---

### Phase D: Token Analysis (Experiment H)

**Goal**: A standalone token/cost analyser that covers 100% of Exp A+B reviews.

**Deliverables:**
- `analysis/token_analysis.py` — token aggregation CLI (FR-006)
- Per-run CSV and per-group summary JSON

**Acceptance gate:** Running `token_analysis.py` against a directory of
ReviewResponse files produces a CSV with one row per run and a summary JSON
with mean/std cost per language × condition group.

**Effort estimate:** 1 day

---

### Phase E: Report Generator

**Goal**: A single report generator that produces all four Markdown reports
required by FR-007 and SC-005.

**Deliverables:**
- `review/report.py` — report generator (FR-007)
- `experiments/track1/reports/experiment-a.md`
- `experiments/track1/reports/experiment-b.md`
- `experiments/track1/reports/experiment-h.md`
- `experiments/track1/reports/comparison-table.md`

**Acceptance gate:** The comparison table distinguishes at least 2 conditions
× 2 languages with mean DDR, FPR, and mean review cost (SC-005).

**Effort estimate:** 1 day

---

### Phase F: Orchestration + Documentation

**Goal**: A single script that runs the full pipeline end-to-end and
documentation sufficient for a new contributor to reproduce results (SC-006).

**Deliverables:**
- `run-track1.sh` — end-to-end orchestrator (FR-008)
- `quickstart.md` — step-by-step reproduction guide
- Updated `EXPERIMENTS.md` with Track 1 pipeline command
- `.gitignore` entries for `experiments/track1/seeded/` (handled via data branch)

**Acceptance gate:** A new contributor can follow `quickstart.md` to run
`run-track1.sh --dry-run` and understand every output path without reading
source code.

**Effort estimate:** 1 day

---

## Dependencies

```
Phase A (inject)
    └─▶ Phase B (harness)
         └─▶ Phase C (score)
              ├─▶ Phase D (token analysis — parallel)
              └─▶ Phase E (report)
                   └─▶ Phase F (orchestration)
```

Phases D and E are parallel once Phase C is complete.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Bug injection breaks compilation in some Rust implementations due to macro/lifetime interactions | Medium | High | Test each bug template against all 19 Rust targets in Phase A; add language-specific fallback templates |
| Anthropic API rate limits hit during 78-call run | Low | Medium | Retry policy (FR-003a); orchestrator adds 1 s sleep between calls by default |
| Claude reviewer returns findings with no line numbers | Medium | Medium | Score.py handles `null` line_start (classified as FP if file-only match insufficient); documented in scoring algorithm |
| Pricing changes between Exp A and B runs | Low | Low | Pricing stored per-response at call time; `pricing.json` versioned |
| All bugs in a Rust run are co-located by coincidence (PRNG seed) | Low | Low | Catalog designed with distinct injection sites; PRNG selection verified to spread across files |

---

## Constitution Check (Post-Design)

All five tools comply with the implicit project conventions:

| Check | Result |
|-------|--------|
| Tools runnable from CLI without interactive input | ✅ FR-008 enforced in contracts |
| All intermediate artifacts persisted to disk | ✅ FR-009 enforced; orchestrator skips existing |
| JSON for structured data | ✅ All entity schemas are JSON |
| Python 3.9+ for scripting | ✅ No 3.10+ syntax used |
| Markdown for reports | ✅ report.py outputs `.md` files |
| No external deps beyond `anthropic` SDK | ✅ Scorer and analyser use stdlib only |

**Post-design Gate: PASS**
