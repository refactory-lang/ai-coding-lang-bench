# Research: Track 1 — Reviewability Gap (Experiments A, B, H)

**Feature Branch**: `004-track-1-reviewability`  
**Created**: 2026-03-20  
**Status**: Complete — all unknowns resolved

---

## 1. Target Implementation Pool

### Decision
Use all Python and Rust runs from `results/results.json` where both `v1_pass` and `v2_pass` are `true`.

### Findings
Analysis of `results/results.json` (300 total runs, 40 Python+Rust):
- Python: 20/20 trials pass both v1 and v2 → **20 target implementations**
- Rust: 19/20 trials pass both v1 and v2 (trial 1 fails both) → **19 target implementations**
- **Total target pool: 39 implementations** (20 Python + 19 Rust)

Each implementation has a v2 directory (feature-complete) at
`generated/minigit-{lang}-{trial}-v2/` on the `data` branch. The v2 version
is preferred for seeding because it covers all 6 commands tested in v2 (status,
diff, checkout, reset, rm, show) and is more complex, giving bugs more
behavioral surface to hide and review to detect.

### Alternatives Considered
- Seed only v1 (11-test) implementations: rejected — fewer commands means fewer
  viable injection sites for 3 independent bugs.
- Seed both v1 and v2: rejected — doubles API cost with limited analytical gain;
  v2 is strictly a superset.

---

## 2. Bug Catalog Design

### Decision
Pre-define a catalog of **6 logic bug templates** applicable to MiniGit
implementations, split by language (Python / Rust). Each injection run picks
exactly 3 bugs deterministically (by run seed) from the applicable language
sub-catalog. All bugs are logic errors that do not prevent compilation and do
not cause the full test suite to fail.

### Bug Categories (applicable to MiniGit v2)

| ID | Category | Description | Test Impact |
|----|----------|-------------|-------------|
| `OBO-LOG` | off-by-one | Log iterator stops one commit early (fencepost error in parent-chain traversal) | `log` shows N-1 entries |
| `HASH-SEED` | wrong-hash-seed | FNV-1a offset basis initialised with wrong constant (e.g. `0` instead of `14695981039346656037`) | Hashes computed, but non-deterministic across implementations; mismatches on checkout/show |
| `STATUS-STAGE` | wrong-status | Staged files reported as unstaged (or vice versa) in `status` output | Status output incorrect but does not crash |
| `PARENT-NULL` | missing-parent | Commit does not record its parent hash, breaking `log` after the first commit | Log shows only 1 entry regardless of history depth |
| `INDEX-FLUSH` | index-not-flushed | `add` updates in-memory index but does not persist it to `.minigit/index` | Files appear unstaged after process exit |
| `DIFF-BASE` | wrong-diff-base | `diff` compares HEAD against wrong baseline (e.g., previous commit instead of index) | Diff output is stale by one commit |

Each template is parameterised: the injector applies the transformation
mechanically (patch a constant, swap a comparison, drop a write call) so the
mutation is reproducible given the same source file.

### Rationale
- All bugs survive compilation (Python: valid syntax; Rust: `cargo check` passes).
- No single bug trips all 30 v2 test cases — the partial-failure constraint
  (FR-002) is preserved by design: `OBO-LOG` fails only multi-entry log tests;
  `STATUS-STAGE` fails only status-format tests; `INDEX-FLUSH` fails only
  persistence tests that cross process boundaries.
- 6 bugs for 2 languages allows exactly 3 to be drawn per run with no repeats.

### Alternatives Considered
- AST-mutation tools (mutmut, cargo-mutants): rejected — they generate too many
  trivially-detectable mutations and require per-language toolchain setup.
- Random line-deletion: rejected — high probability of compilation failure.

---

## 3. Anthropic API Integration

### Decision
Use the **Anthropic Python SDK** (`anthropic>=0.25`) with `messages.create`,
`max_tokens=4096`, `temperature=0`, and no `tools` parameter.

### Key Parameters
- **Model**: configurable via `--model` flag; default `claude-opus-4-5` (NOTE:
  per spec, user specified `claude-opus-4.6` as the default; the harness config
  must accept any Anthropic model string and pass it through unchanged).
- **Single-pass**: exactly one API call per seeded implementation, no follow-up
  turns, no tool use.
- **System prompt**: encodes the reviewer role and output format
  (structured findings list with file, line range, and description).
- **User prompt**: concatenates all source files in the seeded directory with
  a task instruction: "Review the following code for logic errors."

### Token Budget
From existing benchmark data (`v1_claude`, `v2_claude` fields in
`results/results.json`), v2 Python/Rust implementations average ~300 LOC.
Assuming ~4 chars/token, that is ~300 tokens of source code per file. With a
system prompt of ~500 tokens and output of up to 4096 tokens:
- Input tokens per review: ~1 000 – 2 000
- Output tokens per review: ~500 – 1 500
- Total per run: ~1 500 – 3 500 tokens  
- 39 runs × 2 conditions × 3 500 ≈ **273 000 tokens max** (~$5–$8 at
  claude-opus-4.6 pricing as of 2026-03; minimum ~$4 at 1 500 tokens/call,
  mid-range ~$8 at 3 500 tokens/call)

### Retry Policy (FR-003a)
Exponential backoff: attempt 1 → wait 2 s → attempt 2 → wait 4 s → attempt 3
→ wait 8 s → mark as missing data. SDK-level `APIStatusError` (5xx) and
`RateLimitError` trigger retries; `AuthenticationError` and
`InvalidRequestError` are terminal failures (no retry).

### Alternatives Considered
- OpenAI GPT-4o: rejected — spec explicitly requires Anthropic Claude for
  consistency with existing benchmark infrastructure.
- Agentic multi-turn review: rejected — spec requires single-pass non-agentic
  to establish a reproducible baseline (condition F1).

---

## 4. Scoring Algorithm

### Decision
**Location-based matching**: a reviewer finding is classified as a true
positive (TP) for bug *B* if the finding's reported file and line range
overlaps with bug *B*'s injection site (file + injected line, ±5 lines
tolerance). Co-located bugs share a matching window; any finding that hits the
window is a TP for **all** bugs in that window (per spec clarification).

### Formulas
- **DDR** (Defect Detection Rate) = TP / total_bugs (per run; average across
  runs for the condition).
- **FPR** (False Positive Rate, classical) = FP / (FP + TN) where TN = number
  of distinct non-injected regions (file × 10-line window) not flagged by the
  reviewer. TN is bounded and computable from the source file length and the
  bug manifest.
- **noise_ratio** (project-specific proxy) = FP / (FP + FN). Answers "of all
  incorrect reviewer outputs, what fraction were spurious flags?" Useful for
  comparing noise level across conditions; not comparable to classical FPR in
  external literature.

### Determinism
The scorer reads only persisted artifacts (manifest JSON + review response
JSON). Re-running the scorer without new API calls always produces identical
output (SC-003).

### Alternatives Considered
- Keyword matching (grep for bug description): rejected — brittle against
  paraphrased reviewer output.
- Semantic embedding similarity: rejected — adds a second ML call, violating
  the reproducibility and simplicity goals.

---

## 5. Refactory-Profile Constraint (Experiment B)

### Decision
The Refactory-profile constraint is implemented as an **additional system
prompt segment** prepended to the unconstrained reviewer system prompt. It
instructs the AI reviewer to evaluate the Python code under Rust-like
constraints: flag any mutation of shared state without explicit tracking, any
resource (file handle) not closed in a finally/context-manager block, and any
index out of range possibility — mirroring Rust's ownership and safety model
applied to Python.

### Rationale
This matches the "Python-as-Rust" description in the spec. The constraint does
not change the output format (same structured findings list), enabling direct
DDR/FPR comparison (US-2, Acceptance Scenario 1).

### Alternatives Considered
- Separate fine-tuned model: not available / out of scope.
- Post-processing filter (only surface "Rust-style" findings): rejected —
  changes the information available to the reviewer before output, which is the
  experimental variable.

---

## 6. Output Artifact Layout

### Decision

```
experiments/track1/
  seeded/
    {lang}-{trial}-v2/         # mutated source copy (data branch)
  manifests/
    {lang}-{trial}-v2.json     # bug manifest per run
  reviews/
    {condition}/
      {lang}-{trial}-v2.json   # raw API response per run
  metrics/
    {lang}-{trial}-v2-{condition}.json   # per-run scored metrics
  reports/
    experiment-a.md            # Experiment A summary
    experiment-b.md            # Experiment B summary
    experiment-h.md            # Experiment H token economics
    comparison-table.md        # Combined A vs B vs H table
```

Seeded source lives on the `data` branch alongside the original generated code.
Manifests, reviews, metrics, and reports live on the feature branch and are
committed as experimental outputs.

### Rationale
Separation of seeded source (large, binary-free) from structured JSON
artifacts allows partial re-runs (re-score without re-seeding; re-report
without re-scoring). The data branch pattern is already established in this
repo.

---

## 7. Technology Stack

| Component | Technology | Justification |
|-----------|-----------|---------------|
| Bug injector | Python 3.x + `ast` module | Parse-based injection is safer than regex for Python; for Rust, line-level patch via `str.replace` suffices for the defined bug templates |
| Review harness | Python 3.x + `anthropic` SDK | Consistent with existing analysis/ scripts; SDK handles auth and retries as base |
| Scorer | Python 3.x (stdlib only) | No ML needed; pure JSON processing |
| Token analyzer | Python 3.x (stdlib only) | API responses already carry token counts |
| Report generator | Python 3.x + Markdown output | Consistent with existing `report.rb`/`report.md` pattern |
| Orchestrator | Shell script (`run-track1.sh`) | Chains tools; easy to run from CI or manually |

All Python tooling targets Python 3.9+ (available in the benchmark environment).
