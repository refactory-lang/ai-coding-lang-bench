"""
analysis/test_token_analysis.py — Unit tests for analysis/token_analysis.py

Runner: python3 -m pytest analysis/test_token_analysis.py -v
"""

import csv
import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(REPO_ROOT / "analysis"))

import token_analysis


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_review_response(
    run_id: str,
    condition: str,
    input_tokens: int = 1800,
    output_tokens: int = 700,
    cost: float = 0.079,
    missing: bool = False,
) -> dict:
    """Create a minimal ReviewResponse dict."""
    lang, trial = token_analysis.parse_run_id(run_id)
    return {
        "run_id": run_id,
        "condition": condition,
        "model": "claude-opus-4.6",
        "reviewed_at": "2026-03-21T10:05:00Z",
        "input_tokens": input_tokens if not missing else 0,
        "output_tokens": output_tokens if not missing else 0,
        "estimated_cost_usd": cost if not missing else 0.0,
        "raw_text": "",
        "findings": [],
        "missing_data": missing,
        "missing_data_reason": None if not missing else "All retries exhausted",
        "retry_count": 0,
    }


def write_review_files(tmp_path: Path, reviews: list) -> Path:
    """
    Write ReviewResponse JSON files into {tmp_path}/{condition}/{run_id}.json.
    Returns the reviews root dir.
    """
    reviews_dir = tmp_path / "reviews"
    for rev in reviews:
        condition = rev["condition"]
        run_id = rev["run_id"]
        out = reviews_dir / condition / f"{run_id}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w") as fh:
            json.dump(rev, fh)
    return reviews_dir


# ---------------------------------------------------------------------------
# Test 1: Happy path — 3 mock ReviewResponse files → CSV has 3 rows
# ---------------------------------------------------------------------------

def test_happy_path_three_files(tmp_path):
    reviews = [
        make_review_response("python-1-v2", "unconstrained", input_tokens=1800, output_tokens=700, cost=0.079),
        make_review_response("python-2-v2", "unconstrained", input_tokens=2000, output_tokens=800, cost=0.087),
        make_review_response("rust-1-v2",   "unconstrained", input_tokens=1600, output_tokens=600, cost=0.069),
    ]
    reviews_dir = write_review_files(tmp_path, reviews)
    output_csv = tmp_path / "out.csv"
    output_summary = tmp_path / "summary.json"

    records = token_analysis.load_review_responses(reviews_dir)
    token_analysis.write_csv(records, output_csv)
    summaries = token_analysis.aggregate_groups(records)

    assert len(records) == 3

    with open(output_csv, newline="") as fh:
        rows = list(csv.DictReader(fh))
    assert len(rows) == 3

    # Check means for python/unconstrained group
    py_group = next(s for s in summaries if s["language"] == "python" and s["condition"] == "unconstrained")
    assert py_group["n_runs"] == 2
    expected_mean_cost = (0.079 + 0.087) / 2
    assert abs(py_group["mean_cost_usd"] - expected_mean_cost) < 1e-5


# ---------------------------------------------------------------------------
# Test 2: Missing data excluded from means
# ---------------------------------------------------------------------------

def test_missing_data_excluded_from_means(tmp_path):
    reviews = [
        make_review_response("python-1-v2", "unconstrained", input_tokens=1800, output_tokens=700, cost=0.079),
        make_review_response("python-2-v2", "unconstrained", missing=True),
        make_review_response("python-3-v2", "unconstrained", input_tokens=2000, output_tokens=800, cost=0.087),
    ]
    reviews_dir = write_review_files(tmp_path, reviews)

    records = token_analysis.load_review_responses(reviews_dir)
    summaries = token_analysis.aggregate_groups(records)

    py = next(s for s in summaries if s["language"] == "python" and s["condition"] == "unconstrained")
    assert py["n_runs"] == 3
    assert py["n_missing"] == 1
    # Mean should be over 2 valid runs only
    expected_mean = (0.079 + 0.087) / 2
    assert abs(py["mean_cost_usd"] - expected_mean) < 1e-5
    # Total should also only count valid runs
    assert abs(py["total_cost_usd"] - (0.079 + 0.087)) < 1e-5


# ---------------------------------------------------------------------------
# Test 3: Group aggregation — 2 languages × 2 conditions → 4 summary entries
# ---------------------------------------------------------------------------

def test_group_aggregation_four_groups(tmp_path):
    reviews = [
        make_review_response("python-1-v2", "unconstrained", cost=0.080),
        make_review_response("python-2-v2", "refactory-profile", cost=0.090),
        make_review_response("rust-1-v2",   "unconstrained", cost=0.075),
        make_review_response("rust-2-v2",   "refactory-profile", cost=0.085),
    ]
    reviews_dir = write_review_files(tmp_path, reviews)

    records = token_analysis.load_review_responses(reviews_dir)
    summaries = token_analysis.aggregate_groups(records)

    assert len(summaries) == 4
    keys = {(s["language"], s["condition"]) for s in summaries}
    assert ("python", "unconstrained") in keys
    assert ("python", "refactory-profile") in keys
    assert ("rust", "unconstrained") in keys
    assert ("rust", "refactory-profile") in keys


# ---------------------------------------------------------------------------
# Test 4: Empty input — no JSON files → empty CSV header row, empty summary
# ---------------------------------------------------------------------------

def test_empty_input(tmp_path):
    reviews_dir = tmp_path / "reviews"
    reviews_dir.mkdir()
    output_csv = tmp_path / "out.csv"

    records = token_analysis.load_review_responses(reviews_dir)
    assert records == []

    token_analysis.write_csv(records, output_csv)
    with open(output_csv, newline="") as fh:
        reader = csv.DictReader(fh)
        rows = list(reader)
    assert len(rows) == 0  # header only, no data rows

    summaries = token_analysis.aggregate_groups(records)
    assert summaries == []


# ---------------------------------------------------------------------------
# Test 5: All 4 groups populated when 78 responses present
# ---------------------------------------------------------------------------

def test_all_four_groups_78_responses(tmp_path):
    """
    Generate 39 unconstrained + 39 refactory-profile responses across
    20 Python + 19 Rust = 39 implementations.
    """
    reviews = []
    for trial in range(1, 21):  # 20 Python
        reviews.append(make_review_response(f"python-{trial}-v2", "unconstrained", cost=0.080))
        reviews.append(make_review_response(f"python-{trial}-v2", "refactory-profile", cost=0.090))
    for trial in range(1, 20):  # 19 Rust
        reviews.append(make_review_response(f"rust-{trial}-v2", "unconstrained", cost=0.075))
        reviews.append(make_review_response(f"rust-{trial}-v2", "refactory-profile", cost=0.085))

    assert len(reviews) == 78

    reviews_dir = write_review_files(tmp_path, reviews)
    records = token_analysis.load_review_responses(reviews_dir)
    summaries = token_analysis.aggregate_groups(records)

    assert len(records) == 78
    assert len(summaries) == 4

    py_unc = next(s for s in summaries if s["language"] == "python" and s["condition"] == "unconstrained")
    py_ref = next(s for s in summaries if s["language"] == "python" and s["condition"] == "refactory-profile")
    rs_unc = next(s for s in summaries if s["language"] == "rust"   and s["condition"] == "unconstrained")
    rs_ref = next(s for s in summaries if s["language"] == "rust"   and s["condition"] == "refactory-profile")

    assert py_unc["n_runs"] == 20
    assert py_ref["n_runs"] == 20
    assert rs_unc["n_runs"] == 19
    assert rs_ref["n_runs"] == 19


# ---------------------------------------------------------------------------
# Test 6: parse_run_id correctly handles various run_id formats
# ---------------------------------------------------------------------------

def test_parse_run_id():
    assert token_analysis.parse_run_id("python-1-v2") == ("python", 1)
    assert token_analysis.parse_run_id("rust-19-v2") == ("rust", 19)
    assert token_analysis.parse_run_id("python-10-v2") == ("python", 10)
    lang, trial = token_analysis.parse_run_id("unknown")
    assert lang == "unknown"


# ---------------------------------------------------------------------------
# Test 7: Summary has all required fields
# ---------------------------------------------------------------------------

def test_summary_schema(tmp_path):
    reviews = [make_review_response("python-1-v2", "unconstrained", cost=0.079)]
    reviews_dir = write_review_files(tmp_path, reviews)
    records = token_analysis.load_review_responses(reviews_dir)
    summaries = token_analysis.aggregate_groups(records)

    assert len(summaries) == 1
    s = summaries[0]
    required_fields = {
        "condition", "language", "n_runs", "n_missing",
        "mean_input_tokens", "std_input_tokens",
        "mean_output_tokens", "std_output_tokens",
        "mean_cost_usd", "std_cost_usd",
        "total_input_tokens", "total_output_tokens", "total_cost_usd",
    }
    assert required_fields.issubset(set(s.keys()))


# ---------------------------------------------------------------------------
# Test T-8: All-missing group → mean fields are None, not 0.0 (T-8 coverage)
# ---------------------------------------------------------------------------

def test_all_missing_group_returns_none_means():
    """
    When every record in a group is missing_data=True, mean_* fields must be
    None (no data), not 0.0 (measurably zero).  Ensures alignment with
    review/report._mean([]) == None.
    """
    # Build records in the internal format that aggregate_groups expects
    # (as produced by load_review_responses — includes language/trial fields).
    def _internal(run_id, condition, missing=True):
        lang, trial = token_analysis.parse_run_id(run_id)
        return {
            "run_id": run_id,
            "condition": condition,
            "language": lang,
            "trial": trial,
            "input_tokens": 0,
            "output_tokens": 0,
            "estimated_cost_usd": 0.0,
            "missing_data": missing,
        }

    records = [
        _internal("python-1-v2", "unconstrained"),
        _internal("python-2-v2", "unconstrained"),
        _internal("python-3-v2", "unconstrained"),
    ]
    summaries = token_analysis.aggregate_groups(records)
    assert len(summaries) == 1
    s = summaries[0]

    assert s["n_runs"] == 3
    assert s["n_missing"] == 3
    # All runs missing → no valid token data → means must be None, not 0.0
    assert s["mean_input_tokens"] is None, (
        f"Expected mean_input_tokens=None for all-missing group, got {s['mean_input_tokens']}"
    )
    assert s["mean_output_tokens"] is None
    assert s["mean_cost_usd"] is None
    # Totals are still computable (sum of empty list = 0)
    assert s["total_cost_usd"] == 0.0
