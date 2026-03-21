# Data Model: Track 1 — Reviewability Gap (Experiments A, B, H)

**Feature Branch**: `004-track-1-reviewability`  
**Created**: 2026-03-20

---

## Overview

All intermediate and final artifacts are stored as JSON files on disk. There is
no database. The entities below map directly to file schemas persisted under
`experiments/track1/`.

---

## Entity: BugDefinition

Represents a single entry in the pre-defined bug catalog (`bugs/catalog.json`).

```json
{
  "id": "OBO-LOG",
  "category": "off-by-one",
  "language": "python",
  "description": "Log iterator stops one commit early — fencepost error in parent-chain traversal.",
  "affected_commands": ["log"],
  "test_impact": "Fails multi-entry log tests; first-commit log still passes.",
  "injection_strategy": "Replace stop condition in parent-chain loop: change `while parent:` to `while parent and depth < limit - 1:`"
}
```

| Field | Type | Constraints |
|-------|------|-------------|
| `id` | string | Unique across catalog; format `[A-Z]+-[A-Z]+` |
| `category` | string | Enum: `off-by-one`, `wrong-hash-seed`, `wrong-status`, `missing-parent`, `index-not-flushed`, `wrong-diff-base` |
| `language` | string | `python` or `rust` |
| `description` | string | Human-readable, max 200 chars |
| `affected_commands` | string[] | Subset of: `init`, `add`, `commit`, `log`, `status`, `diff`, `checkout`, `reset`, `rm`, `show` |
| `test_impact` | string | Which tests fail/pass after injection |
| `injection_strategy` | string | Precise mechanical description of the source transformation |

**Validation Rules:**
- `id` must be unique within the catalog.
- `language` must match the target implementation language exactly.
- `affected_commands` must be non-empty.
- `injection_strategy` must be deterministic and unambiguous.

---

## Entity: BugManifest

Produced by `bugs/inject.py` for each seeded implementation. Stored at
`experiments/track1/manifests/{lang}-{trial}-v2.json`.

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
      "bug_id": "OBO-LOG",
      "category": "off-by-one",
      "file_path": "minigit.py",
      "line_number": 87,
      "description": "Log stops one commit early",
      "original_line": "while parent:",
      "injected_line": "while parent and depth < max_entries - 1:"
    }
  ]
}
```

| Field | Type | Constraints |
|-------|------|-------------|
| `run_id` | string | `{language}-{trial}-{version}`; unique per experiment |
| `language` | string | `python` or `rust` |
| `trial` | integer | 1–20 |
| `version` | string | `v1` or `v2` (always `v2` in Track 1) |
| `source_dir` | string | Relative path on `data` branch |
| `seeded_dir` | string | Relative path to mutated copy |
| `injected_at` | string | ISO 8601 timestamp |
| `bugs` | BugInjection[] | Exactly 3 elements |

### BugInjection (embedded in BugManifest)

| Field | Type | Constraints |
|-------|------|-------------|
| `bug_id` | string | Must reference a valid `BugDefinition.id` |
| `category` | string | Copied from BugDefinition |
| `file_path` | string | Relative to `seeded_dir` |
| `line_number` | integer | 1-indexed; line of injected code in the seeded file |
| `description` | string | Short human-readable label |
| `original_line` | string | The exact source line before injection |
| `injected_line` | string | The exact source line after injection |

---

## Entity: ReviewRequest (logical, not persisted)

Represents the inputs assembled by `review/harness.py` before the API call.
Not persisted independently — captured in the ReviewResponse.

| Field | Type | Notes |
|-------|------|-------|
| `run_id` | string | `{language}-{trial}-v2` |
| `condition` | string | `unconstrained` or `refactory-profile` |
| `model` | string | e.g. `claude-opus-4.6` |
| `system_prompt` | string | Condition-dependent prompt text |
| `user_prompt` | string | Concatenated source files + task instruction |

---

## Entity: ReviewResponse

Raw API response persisted by `review/harness.py`. Stored at
`experiments/track1/reviews/{condition}/{lang}-{trial}-v2.json`.

```json
{
  "run_id": "python-1-v2",
  "condition": "unconstrained",
  "model": "claude-opus-4.6",
  "reviewed_at": "2026-03-21T10:05:00Z",
  "input_tokens": 1842,
  "output_tokens": 743,
  "finish_reason": "end_turn",
  "price_per_1k_input_usd": 0.015,
  "price_per_1k_output_usd": 0.075,
  "estimated_cost_usd": 0.0834,
  "raw_text": "## Code Review Findings\n\n1. **File**: minigit.py, **Lines**: 85–90 ...",
  "findings": [
    {
      "finding_id": "F1",
      "file_path": "minigit.py",
      "line_start": 85,
      "line_end": 92,
      "description": "Log traversal loop condition appears to terminate one step early; may miss the oldest commit."
    }
  ],
  "missing_data": false,
  "missing_data_reason": null,
  "retry_count": 0
}
```

| Field | Type | Constraints |
|-------|------|-------------|
| `run_id` | string | Must reference a valid BugManifest `run_id` |
| `condition` | string | `unconstrained` or `refactory-profile` |
| `model` | string | Must match the model used for the API call |
| `reviewed_at` | string | ISO 8601 |
| `input_tokens` | integer | ≥ 0 |
| `output_tokens` | integer | ≥ 0; 0 if `missing_data` is true |
| `finish_reason` | string | Anthropic stop reason; `null` if missing |
| `price_per_1k_input_usd` | float | Snapshot at time of call |
| `price_per_1k_output_usd` | float | Snapshot at time of call |
| `estimated_cost_usd` | float | `(input_tokens/1000)*price_in + (output_tokens/1000)*price_out` |
| `raw_text` | string | Full text from `content[0].text`; empty string if missing |
| `findings` | ReviewFinding[] | Parsed by harness; empty list if review found no issues |
| `missing_data` | boolean | `true` if all 3 retries exhausted |
| `missing_data_reason` | string | Error message; `null` if not missing |
| `retry_count` | integer | 0–3 |

### ReviewFinding (embedded in ReviewResponse)

| Field | Type | Constraints |
|-------|------|-------------|
| `finding_id` | string | Sequential within a response: `F1`, `F2`, … |
| `file_path` | string | As reported by the reviewer |
| `line_start` | integer | 1-indexed; `null` if reviewer did not cite a line |
| `line_end` | integer | ≥ `line_start`; `null` if reviewer did not cite a range |
| `description` | string | Verbatim reviewer text for this finding |

---

## Entity: RunMetrics

Produced by `review/score.py`. Stored at
`experiments/track1/metrics/{lang}-{trial}-v2-{condition}.json`.

```json
{
  "run_id": "python-1-v2",
  "condition": "unconstrained",
  "language": "python",
  "trial": 1,
  "version": "v2",
  "total_bugs": 3,
  "tp_count": 2,
  "fp_count": 1,
  "fn_count": 1,
  "tn_count": 42,
  "ddr": 0.6667,
  "fpr": 0.0233,
  "noise_ratio": 0.3333,
  "input_tokens": 1842,
  "output_tokens": 743,
  "estimated_cost_usd": 0.0834,
  "missing_data": false
}
```

| Field | Type | Constraints |
|-------|------|-------------|
| `run_id` | string | Unique per (implementation, condition) |
| `condition` | string | `unconstrained` or `refactory-profile` |
| `language` | string | `python` or `rust` |
| `trial` | integer | 1–20 |
| `total_bugs` | integer | Always 3 |
| `tp_count` | integer | 0–3 |
| `fp_count` | integer | ≥ 0 |
| `fn_count` | integer | `total_bugs - tp_count` |
| `tn_count` | integer | Count of non-injected file regions (file × 10-line window) not flagged; used for classical FPR |
| `ddr` | float | `tp_count / total_bugs`; range [0, 1] |
| `fpr` | float | Classical: `fp_count / (fp_count + tn_count)` when denominator > 0; `0` otherwise |
| `noise_ratio` | float | Project proxy: `fp_count / (fp_count + fn_count)` when denominator > 0; `0` otherwise |
| `input_tokens` | integer | From ReviewResponse |
| `output_tokens` | integer | From ReviewResponse |
| `estimated_cost_usd` | float | From ReviewResponse |
| `missing_data` | boolean | Propagated from ReviewResponse |

**State Transitions:**
```
BugManifest + ReviewResponse → [score.py] → RunMetrics
```
RunMetrics are immutable once written. Re-scoring regenerates the file from
source artifacts only.

---

## Entity: ExperimentSummary

Produced by `review/report.py`. Stored in `experiments/track1/reports/`.

```json
{
  "condition": "unconstrained",
  "language": "python",
  "n_runs": 20,
  "n_missing": 0,
  "mean_ddr": 0.72,
  "std_ddr": 0.18,
  "mean_fpr": 0.021,
  "std_fpr": 0.009,
  "mean_noise_ratio": 0.15,
  "std_noise_ratio": 0.11,
  "mean_cost_usd": 0.081,
  "std_cost_usd": 0.012,
  "total_input_tokens": 36840,
  "total_output_tokens": 14860,
  "total_cost_usd": 1.62
}
```

| Field | Type | Constraints |
|-------|------|-------------|
| `condition` | string | `unconstrained` or `refactory-profile` |
| `language` | string | `python` or `rust` |
| `n_runs` | integer | ≥ 1 |
| `n_missing` | integer | Count of `missing_data: true` runs |
| `mean_ddr` | float | [0, 1]; computed over non-missing runs |
| `std_ddr` | float | ≥ 0 |
| `mean_fpr` | float | [0, 1]; classical FPR; computed over non-missing runs |
| `std_fpr` | float | ≥ 0 |
| `mean_noise_ratio` | float | [0, 1]; project proxy metric |
| `std_noise_ratio` | float | ≥ 0 |
| `mean_cost_usd` | float | ≥ 0 |
| `std_cost_usd` | float | ≥ 0 |
| `total_input_tokens` | integer | Sum across all runs in group |
| `total_output_tokens` | integer | Sum across all runs in group |
| `total_cost_usd` | float | Sum across all runs in group |

---

## Relationships

```
BugDefinition (catalog)
    └─ referenced by ──▶ BugInjection.bug_id (in BugManifest)

BugManifest (one per implementation)
    └─ used by ──────────▶ score.py to produce RunMetrics

ReviewResponse (one per implementation × condition)
    └─ used by ──────────▶ score.py to produce RunMetrics
    └─ used by ──────────▶ token_analysis.py to produce ExperimentSummary (H)

RunMetrics (one per implementation × condition)
    └─ aggregated by ────▶ report.py to produce ExperimentSummary (A, B)

ExperimentSummary × 4 (python/unconstrained, python/refactory-profile,
                        rust/unconstrained, rust/refactory-profile)
    └─ compared by ──────▶ report.py comparison-table.md (SC-005)
```

---

## Artifact Lifecycle

| Stage | Tool | Input → Output |
|-------|------|----------------|
| 1. Seed | `bugs/inject.py` | source dir → seeded dir + BugManifest |
| 2. Review | `review/harness.py` | seeded dir + condition → ReviewResponse |
| 3. Score | `review/score.py` | BugManifest + ReviewResponse → RunMetrics |
| 4. Analyse | `analysis/token_analysis.py` | ReviewResponse files → token/cost CSVs |
| 5. Report | `review/report.py` | RunMetrics files → ExperimentSummary + Markdown |
