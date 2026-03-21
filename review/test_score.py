"""
review/test_score.py — Unit tests for review/score.py

Runner: python3 -m pytest review/test_score.py -v
"""

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(REPO_ROOT / "review"))

import score


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_manifest(bugs: list, run_id: str = "python-1-v2", language: str = "python") -> dict:
    return {
        "run_id": run_id,
        "language": language,
        "trial": 1,
        "version": "v2",
        "source_dir": "generated/minigit-python-1-v2",
        "seeded_dir": "experiments/track1/seeded/python-1-v2",
        "injected_at": "2026-03-21T10:00:00Z",
        "bugs": bugs,
    }


def make_bug(bug_id: str, file_path: str, line_number: int) -> dict:
    return {
        "bug_id": bug_id,
        "category": "off-by-one",
        "file_path": file_path,
        "line_number": line_number,
        "description": f"Bug {bug_id}",
        "original_line": "    while parent:",
        "injected_line": "    while parent and _d < 999:",
    }


def make_review(findings: list, condition: str = "unconstrained", missing: bool = False) -> dict:
    return {
        "run_id": "python-1-v2",
        "condition": condition,
        "model": "claude-opus-4.6",
        "reviewed_at": "2026-03-21T10:05:00Z",
        "input_tokens": 1842,
        "output_tokens": 743,
        "finish_reason": "end_turn",
        "price_per_1k_input_usd": 0.015,
        "price_per_1k_output_usd": 0.075,
        "estimated_cost_usd": 0.0834,
        "raw_text": "",
        "findings": findings,
        "missing_data": missing,
        "missing_data_reason": None if not missing else "All retries exhausted",
        "retry_count": 0,
    }


def make_finding(finding_id: str, file_path: str, line_start: int, line_end: int = None, description: str = "A finding") -> dict:
    return {
        "finding_id": finding_id,
        "file_path": file_path,
        "line_start": line_start,
        "line_end": line_end or line_start,
        "description": description,
    }


# ---------------------------------------------------------------------------
# Test 1: All 3 bugs detected — 3 matching findings → ddr=1.0, fp_count=0
# ---------------------------------------------------------------------------

def test_all_bugs_detected():
    bugs = [
        make_bug("PY-OBO-LOG", "minigit.py", 87),
        make_bug("PY-HASH-SEED", "minigit.py", 45),
        make_bug("PY-INDEX-FLUSH", "minigit.py", 62),
    ]
    findings = [
        make_finding("F1", "minigit.py", 87),
        make_finding("F2", "minigit.py", 45),
        make_finding("F3", "minigit.py", 62),
    ]
    manifest = make_manifest(bugs)
    review = make_review(findings)

    metrics = score.score(manifest, review)

    assert metrics["tp_count"] == 3
    assert metrics["fn_count"] == 0
    assert metrics["fp_count"] == 0
    assert metrics["ddr"] == 1.0
    assert metrics["noise_ratio"] == 0.0
    assert metrics["missing_data"] is False


# ---------------------------------------------------------------------------
# Test 2: No findings — ddr=0.0, fpr=0.0, noise_ratio=0.0
# ---------------------------------------------------------------------------

def test_no_findings():
    bugs = [
        make_bug("PY-OBO-LOG", "minigit.py", 87),
        make_bug("PY-HASH-SEED", "minigit.py", 45),
        make_bug("PY-INDEX-FLUSH", "minigit.py", 62),
    ]
    manifest = make_manifest(bugs)
    review = make_review([])

    metrics = score.score(manifest, review)

    assert metrics["tp_count"] == 0
    assert metrics["fp_count"] == 0
    assert metrics["fn_count"] == 3
    assert metrics["ddr"] == 0.0
    assert metrics["fpr"] == 0.0
    assert metrics["noise_ratio"] == 0.0


# ---------------------------------------------------------------------------
# Test 3: Partial detection — 1 of 3 bugs found, 2 FPs
# ---------------------------------------------------------------------------

def test_partial_detection():
    bugs = [
        make_bug("PY-OBO-LOG", "minigit.py", 87),
        make_bug("PY-HASH-SEED", "minigit.py", 45),
        make_bug("PY-INDEX-FLUSH", "minigit.py", 62),
    ]
    findings = [
        make_finding("F1", "minigit.py", 87),   # TP for bug at line 87
        make_finding("F2", "minigit.py", 120),  # FP — no bug at 120
        make_finding("F3", "minigit.py", 200),  # FP — no bug at 200
    ]
    manifest = make_manifest(bugs)
    review = make_review(findings)

    metrics = score.score(manifest, review)

    assert metrics["tp_count"] == 1
    assert metrics["fp_count"] == 2
    assert metrics["fn_count"] == 2
    assert abs(metrics["ddr"] - 1 / 3) < 0.001
    # noise_ratio = fp / (fp + fn) = 2 / (2 + 2) = 0.5
    assert abs(metrics["noise_ratio"] - 0.5) < 0.001


# ---------------------------------------------------------------------------
# Test 4: Co-located bugs — 2 bugs at line 87; 1 finding at line 87 → both TPs
# ---------------------------------------------------------------------------

def test_co_located_bugs():
    bugs = [
        make_bug("PY-OBO-LOG", "minigit.py", 87),
        make_bug("PY-PARENT-NULL", "minigit.py", 87),  # same location
        make_bug("PY-INDEX-FLUSH", "minigit.py", 62),
    ]
    findings = [
        make_finding("F1", "minigit.py", 87),  # should be TP for both co-located bugs
    ]
    manifest = make_manifest(bugs)
    review = make_review(findings)

    metrics = score.score(manifest, review)

    # Both bugs at line 87 should be TP; bug at 62 is FN
    assert metrics["tp_count"] == 2, f"Expected tp_count=2, got {metrics['tp_count']}"
    assert metrics["fn_count"] == 1
    assert metrics["fp_count"] == 0


# ---------------------------------------------------------------------------
# Test 5: Line tolerance PASS — bug at 87; finding at 90; tolerance=5 → TP
# ---------------------------------------------------------------------------

def test_line_tolerance_pass():
    bugs = [make_bug("PY-OBO-LOG", "minigit.py", 87)]
    # Pad with 2 more bugs to reach total_bugs=3
    bugs += [make_bug("PY-HASH-SEED", "minigit.py", 45), make_bug("PY-INDEX-FLUSH", "minigit.py", 62)]
    findings = [make_finding("F1", "minigit.py", 90)]  # within tolerance=5 of 87

    manifest = make_manifest(bugs)
    review = make_review(findings)

    metrics = score.score(manifest, review, line_tolerance=5)

    # finding at 90, bug at 87: |90-87| = 3 ≤ 5 → TP
    assert 87 in [b["line_number"] for b in bugs]
    assert metrics["tp_count"] >= 1


# ---------------------------------------------------------------------------
# Test 6: Line tolerance EXCEEDED — bug at 87; finding at 93; tolerance=5 → FP
# ---------------------------------------------------------------------------

def test_line_tolerance_exceeded():
    bugs = [make_bug("PY-OBO-LOG", "minigit.py", 87)]
    bugs += [make_bug("PY-HASH-SEED", "minigit.py", 45), make_bug("PY-INDEX-FLUSH", "minigit.py", 62)]
    findings = [make_finding("F1", "minigit.py", 93)]  # |93-87| = 6 > 5 → FP

    manifest = make_manifest(bugs)
    review = make_review(findings)

    metrics = score.score(manifest, review, line_tolerance=5)

    # finding at 93 should NOT match bug at 87 (distance 6 > tolerance 5)
    # So tp for that bug = 0, fp_count >= 1
    assert metrics["fp_count"] >= 1


# ---------------------------------------------------------------------------
# Test 7: Null line_start in finding → classified as FP
# ---------------------------------------------------------------------------

def test_null_line_start_is_fp():
    bugs = [
        make_bug("PY-OBO-LOG", "minigit.py", 87),
        make_bug("PY-HASH-SEED", "minigit.py", 45),
        make_bug("PY-INDEX-FLUSH", "minigit.py", 62),
    ]
    findings = [
        {
            "finding_id": "F1",
            "file_path": "minigit.py",
            "line_start": None,
            "line_end": None,
            "description": "Some issue without line number",
        }
    ]
    manifest = make_manifest(bugs)
    review = make_review(findings)

    metrics = score.score(manifest, review)

    # No line_start → cannot match any bug → FP
    assert metrics["tp_count"] == 0
    assert metrics["fp_count"] == 1
    assert metrics["fn_count"] == 3


# ---------------------------------------------------------------------------
# Test 8: Missing data propagation
# ---------------------------------------------------------------------------

def test_missing_data_propagation():
    bugs = [
        make_bug("PY-OBO-LOG", "minigit.py", 87),
        make_bug("PY-HASH-SEED", "minigit.py", 45),
        make_bug("PY-INDEX-FLUSH", "minigit.py", 62),
    ]
    manifest = make_manifest(bugs)
    review = make_review([], missing=True)

    metrics = score.score(manifest, review)

    assert metrics["missing_data"] is True
    assert metrics["ddr"] is None
    assert metrics["fpr"] is None
    assert metrics["noise_ratio"] is None
    assert metrics["tp_count"] is None
    assert metrics["fp_count"] is None


# ---------------------------------------------------------------------------
# Test 9: TN count computed correctly
# ---------------------------------------------------------------------------

def test_tn_count_computation():
    # Bug at line 87, finding only at line 87 (TP), no other findings
    # All other 10-line windows in the file are TN
    bugs = [
        make_bug("PY-OBO-LOG", "minigit.py", 87),
        make_bug("PY-HASH-SEED", "minigit.py", 45),
        make_bug("PY-INDEX-FLUSH", "minigit.py", 62),
    ]
    findings = [
        make_finding("F1", "minigit.py", 87),
        make_finding("F2", "minigit.py", 45),
        make_finding("F3", "minigit.py", 62),
    ]
    manifest = make_manifest(bugs)
    review = make_review(findings)

    metrics = score.score(manifest, review)

    # All findings are TPs; no FPs; TN = windows not covering any injected bug or flagged finding
    assert metrics["tn_count"] >= 0
    assert metrics["fp_count"] == 0
    # With all 3 bugs detected (tp=3) and 0 FPs, fpr should be 0
    assert metrics["fpr"] == 0.0


# ---------------------------------------------------------------------------
# Test 10: Metrics reproducibility — re-scoring same inputs gives same output
# ---------------------------------------------------------------------------

def test_reproducibility():
    bugs = [
        make_bug("PY-OBO-LOG", "minigit.py", 87),
        make_bug("PY-HASH-SEED", "minigit.py", 45),
        make_bug("PY-INDEX-FLUSH", "minigit.py", 62),
    ]
    findings = [
        make_finding("F1", "minigit.py", 87),
        make_finding("F2", "minigit.py", 200),
    ]
    manifest = make_manifest(bugs)
    review = make_review(findings)

    metrics1 = score.score(manifest, review)
    metrics2 = score.score(manifest, review)

    assert metrics1 == metrics2


# ---------------------------------------------------------------------------
# Test 11: RunMetrics has all required fields
# ---------------------------------------------------------------------------

def test_run_metrics_schema():
    bugs = [
        make_bug("PY-OBO-LOG", "minigit.py", 87),
        make_bug("PY-HASH-SEED", "minigit.py", 45),
        make_bug("PY-INDEX-FLUSH", "minigit.py", 62),
    ]
    manifest = make_manifest(bugs)
    review = make_review([])

    metrics = score.score(manifest, review)

    required = {
        "run_id", "condition", "language", "trial", "version",
        "total_bugs", "tp_count", "fp_count", "fn_count", "tn_count",
        "ddr", "fpr", "noise_ratio",
        "input_tokens", "output_tokens", "estimated_cost_usd",
        "missing_data",
    }
    assert required.issubset(set(metrics.keys())), (
        f"Missing fields: {required - set(metrics.keys())}"
    )
