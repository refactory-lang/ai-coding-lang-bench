"""
review/test_report.py — Unit tests for review/report.py

Runner: python3 -m pytest review/test_report.py -v
"""

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(REPO_ROOT / "review"))

import report


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_run_metrics(
    run_id: str,
    condition: str,
    language: str,
    trial: int = 1,
    tp: int = 2,
    fp: int = 1,
    fn: int = 1,
    tn: int = 42,
    cost: float = 0.081,
    missing: bool = False,
) -> dict:
    total_bugs = tp + fn
    ddr = tp / total_bugs if total_bugs > 0 and not missing else None
    fpr_d = fp + tn
    fpr = fp / fpr_d if fpr_d > 0 and not missing else None
    nr_d = fp + fn
    nr = fp / nr_d if nr_d > 0 and not missing else None

    return {
        "run_id": run_id,
        "condition": condition,
        "language": language,
        "trial": trial,
        "version": "v2",
        "total_bugs": total_bugs,
        "tp_count": tp if not missing else None,
        "fp_count": fp if not missing else None,
        "fn_count": fn if not missing else None,
        "tn_count": tn if not missing else None,
        "ddr": round(ddr, 4) if ddr is not None else None,
        "fpr": round(fpr, 4) if fpr is not None else None,
        "noise_ratio": round(nr, 4) if nr is not None else None,
        "input_tokens": 1842 if not missing else 0,
        "output_tokens": 743 if not missing else 0,
        "estimated_cost_usd": cost if not missing else 0.0,
        "missing_data": missing,
    }


# ---------------------------------------------------------------------------
# Test 1: experiment-a.md renders correctly
# ---------------------------------------------------------------------------

def test_experiment_a_renders(tmp_path):
    metrics = [
        make_run_metrics("python-1-v2", "unconstrained", "python", tp=2, fp=1, fn=1, tn=42, cost=0.081),
        make_run_metrics("rust-1-v2",   "unconstrained", "rust",   tp=1, fp=0, fn=2, tn=40, cost=0.075),
    ]
    md = report.render_experiment_a(metrics)

    assert "Experiment A" in md
    assert "Python" in md
    assert "Rust" in md
    # DDR for python: 2/3 ≈ 0.6667
    assert "0.6667" in md or "0.667" in md
    # Table structure
    assert "| Language |" in md
    assert "| DDR" in md or "DDR" in md


def test_experiment_a_table_has_language_rows(tmp_path):
    metrics = [
        make_run_metrics("python-1-v2", "unconstrained", "python", tp=3, fp=0, fn=0, tn=50),
        make_run_metrics("python-2-v2", "unconstrained", "python", tp=1, fp=2, fn=2, tn=48),
        make_run_metrics("rust-1-v2",   "unconstrained", "rust",   tp=2, fp=1, fn=1, tn=45),
    ]
    md = report.render_experiment_a(metrics)

    lines = md.split("\n")
    table_rows = [l for l in lines if l.startswith("| ") and "Language" not in l and "---" not in l]
    # Should have 2 data rows (one per language)
    assert len(table_rows) == 2


# ---------------------------------------------------------------------------
# Test 2: Missing data noted in report
# ---------------------------------------------------------------------------

def test_missing_data_noted_in_report(tmp_path):
    metrics = [
        make_run_metrics("python-1-v2", "unconstrained", "python", tp=2, fn=1, cost=0.081),
        make_run_metrics("python-2-v2", "unconstrained", "python", missing=True),
    ]
    md = report.render_experiment_a(metrics)

    # The "(1 missing)" note should appear somewhere in the Python row
    assert "1 missing" in md


# ---------------------------------------------------------------------------
# Test 3: experiment-h.md cost comparison — delta column shows correct values
# ---------------------------------------------------------------------------

def test_experiment_h_cost_delta(tmp_path):
    token_summary = [
        {
            "condition": "unconstrained",
            "language": "python",
            "n_runs": 10,
            "n_missing": 0,
            "mean_input_tokens": 1800.0,
            "std_input_tokens": 50.0,
            "mean_output_tokens": 700.0,
            "std_output_tokens": 30.0,
            "mean_cost_usd": 0.08,
            "std_cost_usd": 0.002,
            "total_input_tokens": 18000,
            "total_output_tokens": 7000,
            "total_cost_usd": 0.80,
        },
        {
            "condition": "refactory-profile",
            "language": "python",
            "n_runs": 10,
            "n_missing": 0,
            "mean_input_tokens": 2000.0,
            "std_input_tokens": 60.0,
            "mean_output_tokens": 800.0,
            "std_output_tokens": 40.0,
            "mean_cost_usd": 0.09,
            "std_cost_usd": 0.003,
            "total_input_tokens": 20000,
            "total_output_tokens": 8000,
            "total_cost_usd": 0.90,
        },
    ]
    md = report.render_experiment_h(token_summary)

    # Delta for python: 0.09 - 0.08 = +$0.0100 = +12.5%
    assert "0.0100" in md or "+0.01" in md
    assert "12.5%" in md or "+12.5" in md


# ---------------------------------------------------------------------------
# Test 4: comparison-table.md has all required columns
# ---------------------------------------------------------------------------

def test_comparison_table_columns(tmp_path):
    metrics = [
        make_run_metrics("python-1-v2", "unconstrained",      "python"),
        make_run_metrics("python-2-v2", "refactory-profile",  "python"),
        make_run_metrics("rust-1-v2",   "unconstrained",      "rust"),
        make_run_metrics("rust-2-v2",   "refactory-profile",  "rust"),
    ]
    md = report.render_comparison_table(metrics)

    assert "Language" in md
    assert "Condition" in md
    assert "DDR" in md
    assert "FPR" in md
    assert "Noise Ratio" in md or "noise_ratio" in md.lower()
    assert "Mean Cost" in md or "Cost" in md


def test_comparison_table_shows_two_languages_two_conditions(tmp_path):
    metrics = [
        make_run_metrics("python-1-v2", "unconstrained",      "python"),
        make_run_metrics("python-2-v2", "refactory-profile",  "python"),
        make_run_metrics("rust-1-v2",   "unconstrained",      "rust"),
        make_run_metrics("rust-2-v2",   "refactory-profile",  "rust"),
    ]
    md = report.render_comparison_table(metrics)

    assert "Python" in md
    assert "Rust" in md
    assert "unconstrained" in md
    assert "refactory-profile" in md

    lines = md.split("\n")
    data_rows = [l for l in lines if l.startswith("| ") and "Language" not in l and "---" not in l and l.strip() != "|"]
    assert len(data_rows) >= 4, f"Expected ≥ 4 data rows, got: {data_rows}"


# ---------------------------------------------------------------------------
# Test 5: Empty metrics → graceful output with placeholder rows
# ---------------------------------------------------------------------------

def test_empty_metrics_graceful():
    md_a = report.render_experiment_a([])
    md_b = report.render_experiment_b([])
    md_h = report.render_experiment_h([])
    md_c = report.render_comparison_table([])

    for md in [md_a, md_b, md_h, md_c]:
        assert len(md) > 0
        assert "N/A" in md


# ---------------------------------------------------------------------------
# Test 6: aggregate_metrics returns correct fields
# ---------------------------------------------------------------------------

def test_aggregate_metrics_fields():
    metrics = [
        make_run_metrics("python-1-v2", "unconstrained", "python", tp=3, fp=0, fn=0, tn=50, cost=0.08),
        make_run_metrics("python-2-v2", "unconstrained", "python", tp=0, fp=3, fn=3, tn=47, cost=0.09),
    ]
    s = report.aggregate_metrics(metrics, "unconstrained", "python")

    required = {
        "condition", "language", "n_runs", "n_missing",
        "mean_ddr", "std_ddr", "mean_fpr", "std_fpr",
        "mean_noise_ratio", "std_noise_ratio",
        "mean_cost_usd", "std_cost_usd",
        "total_input_tokens", "total_output_tokens", "total_cost_usd",
    }
    assert required.issubset(set(s.keys()))
    assert s["n_runs"] == 2
    assert s["n_missing"] == 0
    # mean_ddr = (1.0 + 0.0) / 2 = 0.5
    assert abs(s["mean_ddr"] - 0.5) < 0.01
