#!/usr/bin/env python3
"""
review/score.py — Scoring Tool for Track 1 Experiments A and B.

Compares saved review responses against the bug manifest and produces
per-run metrics: DDR, classical FPR, and noise_ratio.

Usage:
    python3 review/score.py \\
        --manifest-path PATH \\
        --review-path PATH \\
        --output-path PATH \\
        [--line-tolerance INT]
"""

import argparse
import json
import math
import sys
from pathlib import Path


DEFAULT_LINE_TOLERANCE = 5
# Number of 10-line windows in a "typical" MiniGit file used to estimate TN count
# Each source file is divided into non-overlapping 10-line windows.
# Windows not covered by any finding (and not containing injected bugs) are TN.
WINDOW_SIZE = 10
# Approximate number of lines in a minimal MiniGit implementation (used as fallback)
DEFAULT_FILE_LINES = 200


def load_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _count_file_lines(seeded_dir: str, file_path: str) -> int:
    """
    Return the actual line count for a file in the seeded directory.
    Falls back to DEFAULT_FILE_LINES if the directory or file is unavailable.
    """
    if not seeded_dir:
        return DEFAULT_FILE_LINES
    full_path = Path(seeded_dir) / file_path
    try:
        text = full_path.read_text(encoding="utf-8", errors="replace")
        return max(len(text.splitlines()), 1)
    except OSError:
        return DEFAULT_FILE_LINES


def compute_tn_count(manifest: dict, review: dict, matched_findings: set) -> int:
    """
    Compute the true negative count.

    TN = number of non-injected 10-line windows in the seeded files that
    were NOT flagged by any finding.

    File line counts are read from the actual seeded sources recorded in the
    manifest's ``seeded_dir`` field.  When that directory is unavailable
    (e.g. during unit tests with synthetic manifests), a heuristic fallback
    of DEFAULT_FILE_LINES is used and TN should be treated as approximate.
    """
    seeded_dir = manifest.get("seeded_dir", "")

    # Collect injected bug windows {(file, window_idx)}
    injected_windows = set()
    file_to_bugs = {}
    for bug in manifest.get("bugs", []):
        fp = bug["file_path"]
        ln = bug.get("line_number", 1)
        window_idx = (ln - 1) // WINDOW_SIZE
        injected_windows.add((fp, window_idx))
        file_to_bugs.setdefault(fp, []).append(bug)

    # Collect all files referenced in bugs and findings
    all_files: set = set(file_to_bugs.keys())
    for finding in review.get("findings", []):
        fp = finding.get("file_path", "")
        if fp:
            all_files.add(fp)

    # Compute per-file window counts from actual file lengths
    file_sizes: dict = {}
    for fp in all_files:
        file_sizes[fp] = _count_file_lines(seeded_dir, fp)

    # Total windows across all files
    total_windows = 0
    for fp, size in file_sizes.items():
        n_windows = math.ceil(size / WINDOW_SIZE)
        total_windows += n_windows

    if not file_sizes:
        # No files — can't compute meaningful TN
        return 0

    # Collect all flagged finding windows
    flagged_windows = set()
    for finding in review.get("findings", []):
        fp = finding.get("file_path", "")
        ls = finding.get("line_start")
        le = finding.get("line_end") or ls
        if ls and fp:
            # Mark all windows covered by this finding
            start_win = (ls - 1) // WINDOW_SIZE
            end_win = (le - 1) // WINDOW_SIZE
            for w in range(start_win, end_win + 1):
                flagged_windows.add((fp, w))

    # TN = total windows - injected-bug windows - flagged windows not already injected
    non_injected_flagged = flagged_windows - injected_windows
    tn_windows = total_windows - len(injected_windows) - len(non_injected_flagged)
    return max(0, tn_windows)


def score(
    manifest: dict,
    review: dict,
    line_tolerance: int = DEFAULT_LINE_TOLERANCE,
) -> dict:
    """
    Compute RunMetrics from a BugManifest and ReviewResponse.

    Returns a RunMetrics dict.
    """
    run_id = manifest["run_id"]
    condition = review["condition"]
    language = manifest["language"]
    trial = manifest["trial"]

    # Handle missing data
    if review.get("missing_data", False):
        return {
            "run_id": run_id,
            "condition": condition,
            "language": language,
            "trial": trial,
            "version": manifest.get("version", "v2"),
            "total_bugs": len(manifest.get("bugs", [])),
            "tp_count": None,
            "fp_count": None,
            "fn_count": None,
            "tn_count": None,
            "ddr": None,
            "fpr": None,
            "noise_ratio": None,
            "input_tokens": review.get("input_tokens", 0),
            "output_tokens": review.get("output_tokens", 0),
            "estimated_cost_usd": review.get("estimated_cost_usd", 0.0),
            "missing_data": True,
        }

    bugs = manifest.get("bugs", [])
    findings = review.get("findings", [])
    total_bugs = len(bugs)

    # Match findings to bugs using location-based rule
    # A finding is a TP for bug B if:
    #   finding.file_path == bug.file_path
    #   AND |finding.line_start - bug.line_number| <= line_tolerance
    #
    # Co-location rule: if multiple bugs share the same (file_path, line_number),
    # any finding matching that location is a TP for ALL bugs at that location.

    # Build a map of (file, window) → list of bug indices
    bug_windows: dict = {}  # (file, line_number) → [bug_idx]
    for idx, bug in enumerate(bugs):
        key = (bug["file_path"], bug["line_number"])
        bug_windows.setdefault(key, []).append(idx)

    # For each bug, track whether it was detected
    detected = [False] * total_bugs

    # For each finding, determine if it's a TP
    tp_finding_indices = set()
    for fidx, finding in enumerate(findings):
        f_file = finding.get("file_path", "")
        f_line = finding.get("line_start")

        if f_line is None:
            # Cannot match without a line number — classified as FP
            continue

        for bidx, bug in enumerate(bugs):
            b_file = bug["file_path"]
            b_line = bug["line_number"]

            if f_file == b_file and abs(f_line - b_line) <= line_tolerance:
                # This finding matches this bug's location
                tp_finding_indices.add(fidx)
                # Mark all bugs at this (file, line) location as detected
                # (co-location rule)
                for co_idx in bug_windows.get((b_file, b_line), [bidx]):
                    detected[co_idx] = True

    tp_count = sum(detected)
    fn_count = total_bugs - tp_count

    # FP = findings that are NOT true positives for any bug
    fp_count = len(findings) - len(tp_finding_indices)
    fp_count = max(0, fp_count)

    # Compute TN count
    tn_count = compute_tn_count(manifest, review, tp_finding_indices)

    # Compute metrics
    ddr = tp_count / total_bugs if total_bugs > 0 else 0.0
    fpr_denom = fp_count + tn_count
    fpr = fp_count / fpr_denom if fpr_denom > 0 else 0.0
    noise_denom = fp_count + fn_count
    noise_ratio = fp_count / noise_denom if noise_denom > 0 else 0.0

    return {
        "run_id": run_id,
        "condition": condition,
        "language": language,
        "trial": trial,
        "version": manifest.get("version", "v2"),
        "total_bugs": total_bugs,
        "tp_count": tp_count,
        "fp_count": fp_count,
        "fn_count": fn_count,
        "tn_count": tn_count,
        "ddr": round(ddr, 4),
        "fpr": round(fpr, 4),
        "noise_ratio": round(noise_ratio, 4),
        "input_tokens": review.get("input_tokens", 0),
        "output_tokens": review.get("output_tokens", 0),
        "estimated_cost_usd": review.get("estimated_cost_usd", 0.0),
        "missing_data": False,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Score a review response against the bug manifest to produce RunMetrics."
    )
    parser.add_argument("--manifest-path", required=True, help="Path to BugManifest JSON")
    parser.add_argument("--review-path", required=True, help="Path to ReviewResponse JSON")
    parser.add_argument("--output-path", required=True, help="Path to write RunMetrics JSON")
    parser.add_argument(
        "--line-tolerance",
        type=int,
        default=DEFAULT_LINE_TOLERANCE,
        help=f"Line matching tolerance (default: {DEFAULT_LINE_TOLERANCE})",
    )
    args = parser.parse_args()

    manifest_path = Path(args.manifest_path)
    review_path = Path(args.review_path)
    output_path = Path(args.output_path)

    if not manifest_path.exists():
        print(f"Error: manifest-path '{manifest_path}' not found.", file=sys.stderr)
        sys.exit(1)
    if not review_path.exists():
        print(f"Error: review-path '{review_path}' not found.", file=sys.stderr)
        sys.exit(1)

    manifest = load_json(manifest_path)
    review = load_json(review_path)

    metrics = score(manifest, review, line_tolerance=args.line_tolerance)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as fh:
        json.dump(metrics, fh, indent=2)

    ddr_str = f"{metrics['ddr']:.2f}" if metrics["ddr"] is not None else "N/A"
    fpr_str = f"{metrics['fpr']:.2f}" if metrics["fpr"] is not None else "N/A"
    print(
        f"Scored {metrics['run_id']} [{metrics['condition']}]: "
        f"DDR={ddr_str} FPR={fpr_str}"
    )


if __name__ == "__main__":
    main()
