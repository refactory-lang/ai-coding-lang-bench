# Feature Specification: Track 1 — Reviewability Gap (Experiments A, B, H)

**Feature Branch**: `004-track-1-reviewability`  
**Created**: 2026-03-20  
**Status**: Draft  
**Input**: User description: "Track 1: Reviewability Gap — Experiments A, B, H"

## Overview

Track 1 investigates the *reviewability gap* — the hypothesis that code generated in certain languages or under certain constraints is measurably more or less reviewable by an AI code reviewer.  Three experiments make up this track:

- **Experiment A** — Seeded-Bug Review Accuracy: inject known bugs into code, measure whether a non-agentic AI reviewer finds them.
- **Experiment B** — Constrained Python Review: repeat Experiment A using the "Python-as-Rust" (Refactory-profile) constraint to determine whether the constraint improves or degrades reviewability.
- **Experiment H** — Review Token Economics: analyse the token costs incurred by the review passes in Experiments A and B and produce cost evidence for the reviewability gap.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Bug Injection and Single-Pass Review (Priority: P1)

A researcher selects a set of successful MiniGit implementations (Python and Rust) from earlier benchmark runs, injects 3–5 seeded logic bugs into each implementation, submits each seeded implementation to a non-agentic AI reviewer (single pass, no tool use), and receives a structured review report that records which bugs were detected.

**Why this priority**: This is the core falsifiability test (condition F1). Without a working bug injection and review pipeline, Experiments B and H have nothing to operate on.

**Independent Test**: Can be fully tested by injecting one known bug into a single implementation and verifying the reviewer's report correctly identifies (or misses) that bug, producing a detection score of 0 or 1.

**Acceptance Scenarios**:

1. **Given** a successful Python MiniGit implementation, **When** 3–5 seeded bugs are injected according to the bug catalog, **Then** each mutated file is stored alongside metadata (language, trial ID, bug IDs injected).
2. **Given** a seeded implementation, **When** the non-agentic reviewer runs a single-pass review, **Then** the output includes a structured list of findings with enough detail to classify each finding as a true positive (TP) or false positive (FP) relative to the seed catalog.
3. **Given** review output for a seeded implementation, **When** the reviewer flags a location that corresponds to a seeded bug, **Then** that finding is counted as a detected bug (true positive).
4. **Given** review output for a seeded implementation, **When** the reviewer flags a location that does NOT correspond to a seeded bug, **Then** that finding is counted as a false positive.
5. **Given** all review outputs for one language, **When** metrics are computed, **Then** defect detection rate (DDR) and false positive rate (FPR) are reported per language.

---

### User Story 2 — Constrained Python Review (Experiment B) (Priority: P2)

A researcher repeats Experiment A with the same bug-seeded Python implementations but reviewed under the "Python-as-Rust" (Refactory profile) constraint, then compares DDR and FPR against the unconstrained baseline.

**Why this priority**: Experiment B extends Experiment A with a single additional condition variable (the constraint). It depends on the P1 pipeline being complete but adds important comparative evidence.

**Independent Test**: Can be fully tested by running the constrained review on a single seeded implementation and confirming the output format is identical to Experiment A output so the same scoring logic applies.

**Acceptance Scenarios**:

1. **Given** a seeded Python implementation, **When** the non-agentic reviewer runs with the Refactory-profile constraint active, **Then** the review output uses the same format as Experiment A, enabling direct metric comparison.
2. **Given** constrained and unconstrained review results for the same seeded implementation, **When** DDR and FPR are compared, **Then** the results table clearly shows whether the constraint improves, degrades, or has no effect on reviewability.

---

### User Story 3 — Review Token Economics (Experiment H) (Priority: P3)

A researcher analyses the token counts from all review API calls made during Experiments A and B, computes per-review costs, aggregates by language and condition, and produces a cost-evidence report for the reviewability gap.

**Why this priority**: Experiment H is purely analytical — it re-uses artifacts already produced by Experiments A and B and adds the economic dimension. It has no blockers of its own beyond P1 and P2 being complete.

**Independent Test**: Can be fully tested by processing the saved token logs from a single Experiment A review run and verifying that the summary output (total input tokens, output tokens, estimated cost) is computed correctly.

**Acceptance Scenarios**:

1. **Given** saved API response logs from Experiment A and B review runs, **When** the token-analysis script processes them, **Then** each run's input token count, output token count, and estimated cost are extracted without manual intervention.
2. **Given** token counts per run, **When** they are aggregated by language (Python, Rust) and condition (unconstrained, Refactory-profile), **Then** the report shows mean and variance of cost per review for each group.
3. **Given** cost aggregates for all groups, **When** the report is generated, **Then** it includes a comparison table showing absolute and relative token cost differences between constrained and unconstrained conditions.

---

### Edge Cases

- What happens when a seeded bug is not syntax-detectable (i.e., the code still compiles and passes all MiniGit tests)?
- How does the system handle an AI reviewer that flags zero issues (produces empty findings list)?
- What if two seeded bugs co-locate in the same function — should detection of one count as detection of both?
- What if a review API call fails mid-run — should the run be retried or marked as missing data?
- How are token counts handled when the API provider changes pricing between Experiment A and B runs?

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The bug injection tool MUST accept an implementation directory and a bug count (3–5) and produce a mutated copy with a machine-readable manifest listing each injected bug's ID, type, file path, and line number.
- **FR-002**: Injected bugs MUST be logic errors that do not prevent compilation or cause all MiniGit tests to fail — the implementation must remain partially functional.
- **FR-003**: The review harness MUST submit each seeded implementation to the AI reviewer as a single, non-agentic API call (no tool use, no multi-turn conversation) and save the full response.
- **FR-004**: The review harness MUST support at least two reviewer configurations: (a) unconstrained and (b) Refactory-profile constrained.
- **FR-005**: The scoring tool MUST compare saved review responses against the bug manifest and produce per-run metrics: defect detection rate (DDR) and false positive rate (FPR).
- **FR-006**: The token-analysis tool MUST read saved API response logs and extract: input token count, output token count, and compute estimated cost using the applicable model pricing.
- **FR-007**: The report generator MUST produce a summary table comparing DDR, FPR, and mean review cost across all conditions (language × constraint).
- **FR-008**: All tools MUST be runnable from the command line without interactive input, accepting parameters via arguments or configuration files.
- **FR-009**: All intermediate artifacts (seeded code, review responses, token logs) MUST be persisted to disk so experiments can be re-scored without re-running API calls.

### Key Entities

- **Bug Manifest**: Records which bugs were injected into which implementation; attributes include bug ID, category (e.g., off-by-one, wrong hash operation), file, line, and a short description.
- **Review Response**: The raw text returned by the AI reviewer for a single seeded implementation; stored alongside the run metadata (language, trial, condition).
- **Review Finding**: A single issue raised by the reviewer; classified as TP or FP after comparison with the bug manifest.
- **Run Metrics**: Per-run summary of DDR, FPR, input tokens, output tokens, and estimated cost.
- **Condition**: A named reviewer configuration — currently `unconstrained` (Experiment A) and `refactory-profile` (Experiment B).

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The bug injection tool successfully seeds 3–5 bugs into 100% of target implementations without causing complete test-suite failure.
- **SC-002**: The review harness completes a single-pass review for every seeded implementation without manual intervention, with a failure rate below 5% (retries allowed for transient API errors).
- **SC-003**: The scoring tool produces DDR and FPR values for all runs; results are reproducible — re-running the scorer on saved artifacts produces identical metrics.
- **SC-004**: Experiment H token analysis covers all review calls from Experiments A and B, with zero runs missing from the cost summary.
- **SC-005**: The final comparison table in the report distinguishes at least two conditions (unconstrained vs. Refactory-profile) across at least two languages (Python and Rust), enabling a direct statement about whether constrained code is more or less reviewable.
- **SC-006**: The end-to-end pipeline (inject → review → score → report) can be executed by a new contributor following the documentation without undocumented manual steps.

---

## Assumptions

- The benchmark's existing `results/results.json` and generated code (in the `data` branch) provide the pool of successful Python and Rust implementations to inject bugs into.
- "Non-agentic" means a single API call with no function/tool use enabled and no follow-up turns; this is the baseline reviewability condition.
- The Refactory-profile constraint is an existing, documented prompt profile; its exact definition is outside the scope of this spec but must be referenced by the review harness configuration.
- Model pricing used in Experiment H is fixed at the published rate at the time of the experiment run and stored in the token log metadata.
- A "successful" implementation is one that passed all 11 v1 or all 30 v2 MiniGit test cases in the original benchmark run.
- Bug categories are drawn from a pre-defined catalog (stored under `bugs/`) established before the experiments begin; ad-hoc bug types are not permitted.
