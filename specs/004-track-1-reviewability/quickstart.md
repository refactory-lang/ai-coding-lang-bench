# Track 1 Quickstart — Reviewability Gap Experiments A, B, H

This guide lets a new contributor reproduce all Track 1 results end-to-end
without reading any source code.

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Python | 3.9+ | `python3 --version` |
| pip | any | `pip install anthropic` |
| Anthropic API key | — | `export ANTHROPIC_API_KEY=sk-ant-...` |
| Git | any | access to `data` branch |
| pytest | any | `pip install pytest` (for running tests only) |

```bash
pip install anthropic pytest
export ANTHROPIC_API_KEY="sk-ant-your-key-here"
```

---

## Step 1: Check out the data branch

The 39 MiniGit implementations (20 Python + 19 Rust) live on the `data` branch
under `generated/`. You need them accessible for bug injection.

```bash
# Option A: git worktree (recommended — keeps the main branch clean)
git fetch origin data
git worktree add /tmp/minigit-data data

# Then symlink generated/ into the repo root:
ln -s /tmp/minigit-data/generated generated

# Option B: checkout into a sibling directory
# Replace <repo-url> with the actual repository URL
# git clone --branch data <repo-url> /tmp/minigit-data
# ln -s /tmp/minigit-data/generated generated
```

Verify the pool is accessible:

```bash
ls generated/minigit-python-1-v2 generated/minigit-rust-1-v2
# Should list the implementation files
```

---

## Step 2: Dry-run verification

Always run with `--dry-run` first to verify the full command sequence without
incurring any API costs:

```bash
bash run-track1.sh --dry-run
```

Expected output ends with:

```
=== Dry-run complete ===
  Targets: 39
  Conditions: 2 (unconstrained refactory-profile)
  Would seed: 39 implementations
  Would review: 78 runs
  Would score: 78 runs
  Reports → experiments/track1/reports
```

If you see `Found 0 target implementations`, check that `results/results.json`
exists and contains `v2_pass: true` entries for Python and Rust.

---

## Step 3: Run Experiment A (unconstrained review)

Experiment A injects 3 bugs into every implementation and runs a single-pass
unconstrained Anthropic Claude review.

```bash
bash run-track1.sh --condition unconstrained --model claude-opus-4.6
```

**Expected runtime**: ~2 min for injection + ~10–15 min for 39 API calls.  
**Expected cost**: ~$2.50–$4.00 at claude-opus-4.6 2026-03 pricing.

Progress is printed for each run. Existing review files are skipped (resumable):
if interrupted, just re-run the same command.

---

## Step 4: Run Experiment B (refactory-profile review)

Experiment B re-uses the same seeded implementations from Step 3 but reviews
them under the Rust-constraint (Refactory-profile) system prompt.

```bash
bash run-track1.sh --condition refactory-profile --model claude-opus-4.6
```

**Expected runtime**: ~10–15 min for 39 API calls (no re-injection needed).  
**Expected cost**: ~$2.50–$4.00 (slightly higher than Exp A due to longer prompt).

---

## Step 5: Run both conditions in one pass

You can run Experiments A and B together:

```bash
bash run-track1.sh --condition both --model claude-opus-4.6
```

**Total expected runtime**: ~5 min injection + ~20–25 min for all 78 API calls.  
**Total expected cost**: ~$5–$8.

---

## Step 6: Run Experiment H (token analysis) standalone

If you already have review files and just want to recompute token/cost analysis:

```bash
python3 analysis/token_analysis.py \
  --reviews-dir experiments/track1/reviews \
  --output-csv experiments/track1/reports/token-per-run.csv \
  --output-summary experiments/track1/reports/token-summary.json
```

---

## Step 7: Generate reports

Re-generate all four Markdown reports from existing RunMetrics files (no API
calls needed):

```bash
python3 review/report.py \
  --metrics-dir experiments/track1/metrics \
  --token-summary experiments/track1/reports/token-summary.json \
  --output-dir experiments/track1/reports
```

---

## Step 8: Where to find results

| File | Contents |
|------|----------|
| `experiments/track1/manifests/*.json` | BugManifest per implementation (which bugs were injected) |
| `experiments/track1/reviews/unconstrained/*.json` | Raw Experiment A review responses |
| `experiments/track1/reviews/refactory-profile/*.json` | Raw Experiment B review responses |
| `experiments/track1/metrics/*.json` | Per-run DDR, FPR, noise_ratio, token counts |
| `experiments/track1/reports/experiment-a.md` | Experiment A summary table |
| `experiments/track1/reports/experiment-b.md` | Experiment B summary table |
| `experiments/track1/reports/experiment-h.md` | Token cost analysis |
| `experiments/track1/reports/comparison-table.md` | A vs B side-by-side comparison |
| `experiments/track1/reports/token-per-run.csv` | Per-run token/cost CSV |
| `experiments/track1/reports/token-summary.json` | Per-group aggregated token summary |

---

## Re-scoring without re-calling the API

The scoring step is deterministic and free — you can re-run it any time:

```bash
# Delete only the metrics files (leave reviews/ intact to avoid re-calling the API)
rm experiments/track1/metrics/*.json

# Re-score from saved reviews
bash run-track1.sh --dry-run  # verify
# Remove --dry-run to actually re-score:
# bash run-track1.sh   (this will skip inject and review steps since files exist)
```

Alternatively, re-score a single run:

```bash
python3 review/score.py \
  --manifest-path experiments/track1/manifests/python-1-v2.json \
  --review-path experiments/track1/reviews/unconstrained/python-1-v2.json \
  --output-path experiments/track1/metrics/python-1-v2-unconstrained.json
```

---

## Running the test suite

```bash
python3 -m pytest bugs/ review/ analysis/ -v
```

All 46 tests should pass. No API calls are made (Anthropic client is mocked).

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `No module named 'anthropic'` | `pip install anthropic` |
| `ANTHROPIC_API_KEY not set` | `export ANTHROPIC_API_KEY=sk-ant-...` |
| `Found 0 target implementations` | Check `results/results.json` exists and has `v2_pass: true` entries |
| `source dir not found` | Check out the `data` branch and symlink `generated/` (Step 1) |
| Review exits with code 2 | All retries exhausted — the run is marked as missing data and documented in the report; re-running will skip it (file exists) |
| Want to retry a failed run | Delete the specific review file: `rm experiments/track1/reviews/unconstrained/python-1-v2.json` |
