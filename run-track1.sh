#!/usr/bin/env bash
# run-track1.sh — End-to-end orchestrator for Track 1 Experiments A, B, H
#
# Usage:
#   bash run-track1.sh [--data-branch BRANCH] [--condition CONDITION] \
#                      [--model MODEL] [--dry-run]
#
# Arguments:
#   --data-branch   Git branch containing generated source code (default: data)
#   --condition     unconstrained | refactory-profile | both (default: both)
#   --model         Anthropic model string (default: claude-opus-4.6)
#   --dry-run       Print commands without executing API calls
#
# Exit codes:
#   0   All steps succeeded
#   1   Argument error
#   2   Critical failure (inject tool fails; cannot proceed)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DATA_BRANCH="data"
CONDITION="both"
MODEL="claude-opus-4.6"
DRY_RUN=false

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_JSON="${REPO_ROOT}/results/results.json"
MANIFESTS_DIR="${REPO_ROOT}/experiments/track1/manifests"
SEEDED_DIR="${REPO_ROOT}/experiments/track1/seeded"
REVIEWS_DIR="${REPO_ROOT}/experiments/track1/reviews"
METRICS_DIR="${REPO_ROOT}/experiments/track1/metrics"
REPORTS_DIR="${REPO_ROOT}/experiments/track1/reports"
TOKEN_CSV="${REPORTS_DIR}/token-per-run.csv"
TOKEN_SUMMARY="${REPORTS_DIR}/token-summary.json"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-branch)
      DATA_BRANCH="$2"; shift 2 ;;
    --condition)
      CONDITION="$2"; shift 2 ;;
    --model)
      MODEL="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --help|-h)
      head -20 "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "Error: unknown argument: $1" >&2
      exit 1 ;;
  esac
done

case "$CONDITION" in
  unconstrained|refactory-profile|both) ;;
  *)
    echo "Error: --condition must be unconstrained, refactory-profile, or both" >&2
    exit 1 ;;
esac

# Determine which conditions to run
if [[ "$CONDITION" == "both" ]]; then
  CONDITIONS=("unconstrained" "refactory-profile")
else
  CONDITIONS=("$CONDITION")
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run_cmd() {
  # Print command; execute unless --dry-run
  echo "  + $*"
  if [[ "$DRY_RUN" == "false" ]]; then
    "$@"
  fi
}

ensure_dirs() {
  mkdir -p "$MANIFESTS_DIR" "$SEEDED_DIR" \
           "${REVIEWS_DIR}/unconstrained" "${REVIEWS_DIR}/refactory-profile" \
           "$METRICS_DIR" "$REPORTS_DIR"
}

# ---------------------------------------------------------------------------
# Build target list from results/results.json
# ---------------------------------------------------------------------------
build_targets() {
  python3 - <<'PYEOF'
import json, sys

try:
    with open("results/results.json") as f:
        results = json.load(f)
except Exception as e:
    print(f"Error reading results/results.json: {e}", file=sys.stderr)
    sys.exit(2)

for run in results:
    lang = run.get("language", "")
    trial = run.get("trial", "")
    v2 = run.get("v2_pass")
    # Include runs that passed v2 (or v1 if v2 not present)
    passed = v2 if v2 is not None else run.get("v1_pass", False)
    if lang in ("python", "rust") and trial and passed:
        src = f"generated/minigit-{lang}-{trial}-v2"
        print(f"{lang}:{trial}:{src}")
PYEOF
}

# ---------------------------------------------------------------------------
# Step counters
# ---------------------------------------------------------------------------
N_SEEDED=0
N_SEEDED_SKIPPED=0
N_REVIEWS=0
N_REVIEWS_SKIPPED=0
N_MISSING=0
N_SCORED=0

# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------
echo "=== Track 1 Pipeline ==="
echo "  data-branch : ${DATA_BRANCH}"
echo "  condition   : ${CONDITION}"
echo "  model       : ${MODEL}"
echo "  dry-run     : ${DRY_RUN}"
echo ""

ensure_dirs

# Check out source pool from data branch (if not already present)
if [[ "$DRY_RUN" == "false" ]]; then
  if ! git show "${DATA_BRANCH}:generated/." >/dev/null 2>&1; then
    echo "WARNING: Cannot access '${DATA_BRANCH}' branch. Source pool may be missing." >&2
    echo "         Run: git fetch && git worktree add /tmp/data-branch ${DATA_BRANCH}" >&2
  fi
fi

# Fetch target list
echo "--- Phase 1: Building target list ---"
TARGETS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && TARGETS+=("$line")
done < <(cd "$REPO_ROOT" && build_targets 2>/dev/null || true)

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "WARNING: No target runs found in results/results.json." >&2
  echo "         Ensure results/results.json exists and contains python/rust v2 runs." >&2
  if [[ "$DRY_RUN" == "false" ]]; then
    exit 2
  fi
fi

echo "  Found ${#TARGETS[@]} target implementations"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Bug injection
# ---------------------------------------------------------------------------
echo "--- Phase 2: Bug injection ---"
for target in "${TARGETS[@]}"; do
  IFS=':' read -r lang trial src_subpath <<< "$target"
  run_id="${lang}-${trial}-v2"
  manifest="${MANIFESTS_DIR}/${run_id}.json"
  seeded="${SEEDED_DIR}/${run_id}"

  if [[ "$DRY_RUN" == "false" ]] && [[ -f "$manifest" ]]; then
    echo "  SKIP inject ${run_id} (manifest exists)"
    N_SEEDED_SKIPPED=$((N_SEEDED_SKIPPED + 1))
    continue
  fi

  # Resolve source dir: try data branch worktree, then local path
  src_dir="${REPO_ROOT}/${src_subpath}"
  if [[ ! -d "$src_dir" ]]; then
    echo "  WARN: source dir not found: ${src_dir}" >&2
    if [[ "$DRY_RUN" == "false" ]]; then
      continue
    fi
  fi

  run_cmd python3 "${REPO_ROOT}/bugs/inject.py" \
    --source-dir "${src_dir}" \
    --output-dir "${seeded}" \
    --manifest-path "${manifest}" \
    --language "${lang}" \
    --trial "${trial}" \
    || { echo "Error: inject failed for ${run_id}" >&2; exit 2; }

  N_SEEDED=$((N_SEEDED + 1))
done
echo ""

# ---------------------------------------------------------------------------
# Step 2: Reviews (per condition)
# ---------------------------------------------------------------------------
echo "--- Phase 3: Reviews ---"
for cond in "${CONDITIONS[@]}"; do
  echo "  Condition: ${cond}"
  for target in "${TARGETS[@]}"; do
    IFS=':' read -r lang trial src_subpath <<< "$target"
    run_id="${lang}-${trial}-v2"
    manifest="${MANIFESTS_DIR}/${run_id}.json"
    seeded="${SEEDED_DIR}/${run_id}"
    review_out="${REVIEWS_DIR}/${cond}/${run_id}.json"

    if [[ "$DRY_RUN" == "false" ]] && [[ -f "$review_out" ]]; then
      echo "  SKIP review ${run_id} [${cond}] (response exists)"
      N_REVIEWS_SKIPPED=$((N_REVIEWS_SKIPPED + 1))
      continue
    fi

    review_status=0
    run_cmd python3 "${REPO_ROOT}/review/harness.py" \
      --seeded-dir "${seeded}" \
      --manifest-path "${manifest}" \
      --output-path "${review_out}" \
      --condition "${cond}" \
      --model "${MODEL}" \
      || review_status=$?

    if [[ "${review_status}" -eq 2 ]]; then
      # Missing data: non-fatal, harness already wrote the output file
      N_MISSING=$((N_MISSING + 1))
    elif [[ "${review_status}" -ne 0 ]]; then
      # Terminal error (auth, invalid request) — non-fatal for orchestrator
      echo "  WARN: review harness failed for ${run_id} [${cond}] with exit ${review_status}" >&2
    fi

    N_REVIEWS=$((N_REVIEWS + 1))
  done
done
echo ""

# ---------------------------------------------------------------------------
# Step 3: Scoring (always re-score — deterministic)
# ---------------------------------------------------------------------------
echo "--- Phase 4: Scoring ---"
for cond in "${CONDITIONS[@]}"; do
  for target in "${TARGETS[@]}"; do
    IFS=':' read -r lang trial src_subpath <<< "$target"
    run_id="${lang}-${trial}-v2"
    manifest="${MANIFESTS_DIR}/${run_id}.json"
    review_out="${REVIEWS_DIR}/${cond}/${run_id}.json"
    metrics_out="${METRICS_DIR}/${run_id}-${cond}.json"

    if [[ "$DRY_RUN" == "false" ]] && [[ ! -f "$review_out" ]]; then
      echo "  SKIP score ${run_id} [${cond}] (no review file)"
      continue
    fi

    run_cmd python3 "${REPO_ROOT}/review/score.py" \
      --manifest-path "${manifest}" \
      --review-path "${review_out}" \
      --output-path "${metrics_out}"

    N_SCORED=$((N_SCORED + 1))
  done
done
echo ""

# ---------------------------------------------------------------------------
# Step 4: Token analysis (Experiment H)
# ---------------------------------------------------------------------------
echo "--- Phase 5: Token analysis ---"
run_cmd python3 "${REPO_ROOT}/analysis/token_analysis.py" \
  --reviews-dir "${REVIEWS_DIR}" \
  --output-csv "${TOKEN_CSV}" \
  --output-summary "${TOKEN_SUMMARY}"
echo ""

# ---------------------------------------------------------------------------
# Step 5: Report generation
# ---------------------------------------------------------------------------
echo "--- Phase 6: Report generation ---"
run_cmd python3 "${REPO_ROOT}/review/report.py" \
  --metrics-dir "${METRICS_DIR}" \
  --token-summary "${TOKEN_SUMMARY}" \
  --output-dir "${REPORTS_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== Dry-run complete ==="
  echo "  Targets: ${#TARGETS[@]}"
  echo "  Conditions: ${#CONDITIONS[@]} (${CONDITIONS[*]})"
  echo "  Would seed: ${#TARGETS[@]} implementations"
  echo "  Would review: $((${#TARGETS[@]} * ${#CONDITIONS[@]})) runs"
  echo "  Would score: $((${#TARGETS[@]} * ${#CONDITIONS[@]})) runs"
  echo "  Reports → ${REPORTS_DIR}"
else
  echo "=== Pipeline complete ==="
  echo "  Seeded: $((N_SEEDED + N_SEEDED_SKIPPED)) runs (${N_SEEDED} new, ${N_SEEDED_SKIPPED} skipped)"
  echo "  Reviews: $((N_REVIEWS + N_REVIEWS_SKIPPED)) runs (${N_REVIEWS} new, ${N_REVIEWS_SKIPPED} skipped, ${N_MISSING} missing)"
  echo "  Scored: ${N_SCORED} runs"
  echo "  Reports → ${REPORTS_DIR}"
fi
