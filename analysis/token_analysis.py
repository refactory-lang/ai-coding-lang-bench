#!/usr/bin/env python3
"""
analysis/token_analysis.py — Token & Cost Analyser for Track 1 Experiment H.

Reads all saved ReviewResponse files from Experiments A and B, extracts token
counts, computes costs, and produces per-group cost summaries.

Usage:
    python3 analysis/token_analysis.py \\
        --reviews-dir PATH \\
        --output-csv PATH \\
        --output-summary PATH
"""

import argparse
import csv
import json
import math
import sys
from pathlib import Path


def parse_run_id(run_id: str) -> tuple:
    """
    Parse a run_id like 'python-1-v2' or 'rust-3-v2' into (language, trial).
    Returns (language, trial) or (run_id, 0) if parsing fails.
    """
    parts = run_id.split("-")
    if len(parts) >= 2:
        language = parts[0]
        try:
            trial = int(parts[1])
        except ValueError:
            trial = 0
        return language, trial
    return run_id, 0


def load_review_responses(reviews_dir: Path) -> list:
    """
    Recursively scan reviews_dir for *.json files and parse as ReviewResponse objects.
    Returns a list of dicts with fields needed for token analysis.
    """
    records = []
    if not reviews_dir.exists():
        return records

    for json_file in sorted(reviews_dir.rglob("*.json")):
        try:
            with open(json_file, encoding="utf-8") as fh:
                data = json.load(fh)
        except (json.JSONDecodeError, OSError):
            continue

        # Must have run_id and condition to be a valid ReviewResponse
        if "run_id" not in data or "condition" not in data:
            continue

        run_id = data.get("run_id", "")
        condition = data.get("condition", "")
        language, trial = parse_run_id(run_id)

        # Use language from run_id, but fall back to explicit language field if present
        language = data.get("language") or language

        records.append(
            {
                "run_id": run_id,
                "condition": condition,
                "language": language,
                "trial": trial,
                "input_tokens": data.get("input_tokens", 0) or 0,
                "output_tokens": data.get("output_tokens", 0) or 0,
                "estimated_cost_usd": data.get("estimated_cost_usd", 0.0) or 0.0,
                "missing_data": data.get("missing_data", False),
            }
        )

    return records


def _mean(values: list) -> float:
    if not values:
        return 0.0
    return sum(values) / len(values)


def _std(values: list) -> float:
    if len(values) < 2:
        return 0.0
    m = _mean(values)
    variance = sum((x - m) ** 2 for x in values) / (len(values) - 1)
    return math.sqrt(variance)


def aggregate_groups(records: list) -> list:
    """
    Aggregate records by (language, condition) groups.
    Returns a list of ExperimentSummary-like dicts (token fields only).
    """
    groups: dict = {}
    for rec in records:
        key = (rec["language"], rec["condition"])
        if key not in groups:
            groups[key] = []
        groups[key].append(rec)

    summaries = []
    for (language, condition), group_records in sorted(groups.items()):
        n_runs = len(group_records)
        missing = [r for r in group_records if r["missing_data"]]
        valid = [r for r in group_records if not r["missing_data"]]
        n_missing = len(missing)

        input_tokens = [r["input_tokens"] for r in valid]
        output_tokens = [r["output_tokens"] for r in valid]
        costs = [r["estimated_cost_usd"] for r in valid]

        summaries.append(
            {
                "condition": condition,
                "language": language,
                "n_runs": n_runs,
                "n_missing": n_missing,
                "mean_input_tokens": round(_mean(input_tokens), 2),
                "std_input_tokens": round(_std(input_tokens), 2),
                "mean_output_tokens": round(_mean(output_tokens), 2),
                "std_output_tokens": round(_std(output_tokens), 2),
                "mean_cost_usd": round(_mean(costs), 6),
                "std_cost_usd": round(_std(costs), 6),
                "total_input_tokens": sum(input_tokens),
                "total_output_tokens": sum(output_tokens),
                "total_cost_usd": round(sum(costs), 6),
            }
        )

    return summaries


def write_csv(records: list, output_path: Path) -> None:
    """Write per-run CSV."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "run_id", "condition", "language", "trial",
        "input_tokens", "output_tokens", "estimated_cost_usd", "missing_data",
    ]
    with open(output_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for rec in records:
            writer.writerow(
                {
                    "run_id": rec["run_id"],
                    "condition": rec["condition"],
                    "language": rec["language"],
                    "trial": rec["trial"],
                    "input_tokens": rec["input_tokens"],
                    "output_tokens": rec["output_tokens"],
                    "estimated_cost_usd": rec["estimated_cost_usd"],
                    "missing_data": str(rec["missing_data"]).lower(),
                }
            )


def main():
    parser = argparse.ArgumentParser(
        description="Aggregate token/cost data from ReviewResponse files (Experiment H)."
    )
    parser.add_argument(
        "--reviews-dir",
        required=True,
        help="Root directory containing {condition}/ subdirs of ReviewResponse JSON files",
    )
    parser.add_argument("--output-csv", required=True, help="Path to write per-run token CSV")
    parser.add_argument(
        "--output-summary", required=True, help="Path to write per-group summary JSON"
    )
    args = parser.parse_args()

    reviews_dir = Path(args.reviews_dir)
    output_csv = Path(args.output_csv)
    output_summary = Path(args.output_summary)

    records = load_review_responses(reviews_dir)
    summaries = aggregate_groups(records)

    write_csv(records, output_csv)

    output_summary.parent.mkdir(parents=True, exist_ok=True)
    with open(output_summary, "w", encoding="utf-8") as fh:
        json.dump(summaries, fh, indent=2)

    print(
        f"Token analysis complete: {len(records)} runs processed, "
        f"{len(summaries)} groups, "
        f"CSV → {output_csv}, summary → {output_summary}"
    )


if __name__ == "__main__":
    main()
