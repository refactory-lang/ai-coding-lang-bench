#!/usr/bin/env python3
"""
review/report.py — Report Generator for Track 1 Experiments A, B, and H.

Aggregates RunMetrics files into ExperimentSummary tables and renders four
Markdown reports.

Usage:
    python3 review/report.py \\
        --metrics-dir PATH \\
        --token-summary PATH \\
        --output-dir PATH
"""

import argparse
import json
import math
import sys
from pathlib import Path


def load_metrics_files(metrics_dir: Path) -> list:
    """Load all RunMetrics JSON files from the metrics directory."""
    metrics = []
    if not metrics_dir.exists():
        return metrics
    for f in sorted(metrics_dir.glob("*.json")):
        try:
            with open(f, encoding="utf-8") as fh:
                data = json.load(fh)
            if "run_id" in data and "condition" in data:
                metrics.append(data)
        except (json.JSONDecodeError, OSError):
            continue
    return metrics


def load_token_summary(token_summary_path: Path) -> list:
    """Load per-group token summary JSON."""
    if not token_summary_path.exists():
        return []
    try:
        with open(token_summary_path, encoding="utf-8") as fh:
            return json.load(fh)
    except (json.JSONDecodeError, OSError):
        return []


def _mean(values: list):
    if not values:
        return None
    return sum(values) / len(values)


def _std(values: list):
    if len(values) < 2:
        return None
    m = _mean(values)
    variance = sum((x - m) ** 2 for x in values) / (len(values) - 1)
    return math.sqrt(variance)


def _round_or_none(value, ndigits: int):
    """Round value to ndigits, or return None if value is None."""
    return round(value, ndigits) if value is not None else None


def aggregate_metrics(metrics_list: list, condition: str, language: str) -> dict:
    """
    Aggregate RunMetrics records for a given (condition, language) group.
    Returns an ExperimentSummary dict.
    """
    group = [
        m for m in metrics_list
        if m.get("condition") == condition and m.get("language") == language
    ]
    n_runs = len(group)
    missing = [m for m in group if m.get("missing_data", False)]
    valid = [m for m in group if not m.get("missing_data", False)]
    n_missing = len(missing)

    ddrs = [m["ddr"] for m in valid if m.get("ddr") is not None]
    fprs = [m["fpr"] for m in valid if m.get("fpr") is not None]
    nrs = [m["noise_ratio"] for m in valid if m.get("noise_ratio") is not None]
    costs = [m["estimated_cost_usd"] for m in valid if m.get("estimated_cost_usd") is not None]
    in_tokens = [m["input_tokens"] for m in valid if m.get("input_tokens") is not None]
    out_tokens = [m["output_tokens"] for m in valid if m.get("output_tokens") is not None]

    return {
        "condition": condition,
        "language": language,
        "n_runs": n_runs,
        "n_missing": n_missing,
        "mean_ddr": _round_or_none(_mean(ddrs), 4),
        "std_ddr": _round_or_none(_std(ddrs), 4),
        "mean_fpr": _round_or_none(_mean(fprs), 4),
        "std_fpr": _round_or_none(_std(fprs), 4),
        "mean_noise_ratio": _round_or_none(_mean(nrs), 4),
        "std_noise_ratio": _round_or_none(_std(nrs), 4),
        "mean_cost_usd": _round_or_none(_mean(costs), 6),
        "std_cost_usd": _round_or_none(_std(costs), 6),
        "total_input_tokens": sum(in_tokens),
        "total_output_tokens": sum(out_tokens),
        "total_cost_usd": round(sum(costs), 6),
    }


def _fmt_missing(n_missing: int) -> str:
    return f" ({n_missing} missing)" if n_missing > 0 else ""


def _fmt_metric(mean_val, std_val, fmt: str = ".4f") -> str:
    """Format mean ± std, rendering N/A when either value is None."""
    if mean_val is None:
        return "N/A"
    if std_val is None:
        return f"{mean_val:{fmt}}"
    return f"{mean_val:{fmt}} ± {std_val:{fmt}}"


def render_experiment_a(metrics_list: list) -> str:
    """Render Experiment A report — unconstrained condition."""
    summaries = []
    for lang in ("python", "rust"):
        s = aggregate_metrics(metrics_list, "unconstrained", lang)
        if s["n_runs"] > 0:
            summaries.append(s)

    lines = [
        "# Experiment A — Seeded-Bug Review Accuracy (Unconstrained)",
        "",
        "Condition: `unconstrained` — single-pass non-agentic Anthropic Claude review.",
        "",
        "## Summary Table",
        "",
        "| Language | N Runs | DDR (mean ± std) | FPR (mean ± std) | Noise Ratio (mean ± std) | Mean Cost (USD) |",
        "|----------|--------|------------------|------------------|--------------------------|-----------------|",
    ]
    for s in summaries:
        missing_note = _fmt_missing(s["n_missing"])
        lang = s["language"].capitalize()
        n_label = f"{s['n_runs']}{missing_note}"
        ddr = _fmt_metric(s["mean_ddr"], s["std_ddr"])
        fpr = _fmt_metric(s["mean_fpr"], s["std_fpr"])
        nr = _fmt_metric(s["mean_noise_ratio"], s["std_noise_ratio"])
        cost = f"${s['mean_cost_usd']:.4f}" if s["mean_cost_usd"] is not None else "N/A"
        lines.append(f"| {lang} | {n_label} | {ddr} | {fpr} | {nr} | {cost} |")

    if not summaries:
        lines.append("| — | 0 | N/A | N/A | N/A | N/A |")

    lines += [
        "",
        "## Metrics Definitions",
        "",
        "- **DDR** (Defect Detection Rate): `TP / total_bugs` — proportion of seeded bugs found.",
        "- **FPR** (False Positive Rate, classical): `FP / (FP + TN)` — proportion of clean regions falsely flagged.",
        "- **Noise Ratio**: `FP / (FP + FN)` — proportion of all non-TP outputs that are false alarms.",
        "",
        "Each implementation was seeded with exactly 3 logic bugs drawn from `bugs/catalog.json`.",
        "",
    ]
    return "\n".join(lines)


def render_experiment_b(metrics_list: list) -> str:
    """Render Experiment B report — refactory-profile condition."""
    summaries = []
    for lang in ("python", "rust"):
        s = aggregate_metrics(metrics_list, "refactory-profile", lang)
        if s["n_runs"] > 0:
            summaries.append(s)

    lines = [
        "# Experiment B — Constrained Review (Refactory-Profile)",
        "",
        "Condition: `refactory-profile` — same as Experiment A but with Rust-like correctness",
        "constraints prepended to the reviewer system prompt.",
        "",
        "## Summary Table",
        "",
        "| Language | N Runs | DDR (mean ± std) | FPR (mean ± std) | Noise Ratio (mean ± std) | Mean Cost (USD) |",
        "|----------|--------|------------------|------------------|--------------------------|-----------------|",
    ]
    for s in summaries:
        missing_note = _fmt_missing(s["n_missing"])
        lang = s["language"].capitalize()
        n_label = f"{s['n_runs']}{missing_note}"
        ddr = _fmt_metric(s["mean_ddr"], s["std_ddr"])
        fpr = _fmt_metric(s["mean_fpr"], s["std_fpr"])
        nr = _fmt_metric(s["mean_noise_ratio"], s["std_noise_ratio"])
        cost = f"${s['mean_cost_usd']:.4f}" if s["mean_cost_usd"] is not None else "N/A"
        lines.append(f"| {lang} | {n_label} | {ddr} | {fpr} | {nr} | {cost} |")

    if not summaries:
        lines.append("| — | 0 | N/A | N/A | N/A | N/A |")

    lines += [
        "",
        "## Refactory-Profile Constraint",
        "",
        "The reviewer was additionally instructed to flag:",
        "1. Mutation of shared state without explicit tracking.",
        "2. File/resource handles not closed in a `finally` block or context manager.",
        "3. Index or key access without bounds/key existence check.",
        "",
        "See `review/prompts/refactory-profile.txt` for the full system prompt.",
        "",
    ]
    return "\n".join(lines)


def render_experiment_h(token_summary: list) -> str:
    """Render Experiment H report — token cost analysis."""
    lines = [
        "# Experiment H — Review Token Economics",
        "",
        "Token-level cost analysis across all Experiment A and B review calls.",
        "",
        "## Per-Group Token Cost Summary",
        "",
        "| Language | Condition | N Runs | Mean Input Tokens | Mean Output Tokens | Mean Cost (USD) | Total Cost (USD) |",
        "|----------|-----------|--------|------------------|--------------------|-----------------|-----------------|",
    ]

    for s in sorted(token_summary, key=lambda x: (x.get("language", ""), x.get("condition", ""))):
        lang = s.get("language", "?").capitalize()
        cond = s.get("condition", "?")
        n = s.get("n_runs", 0)
        missing_note = _fmt_missing(s.get("n_missing", 0))
        n_label = f"{n}{missing_note}"
        mean_in = f"{s.get('mean_input_tokens', 0):.0f}"
        mean_out = f"{s.get('mean_output_tokens', 0):.0f}"
        mean_cost = f"${s.get('mean_cost_usd', 0):.4f}"
        total_cost = f"${s.get('total_cost_usd', 0):.4f}"
        lines.append(
            f"| {lang} | {cond} | {n_label} | {mean_in} | {mean_out} | {mean_cost} | {total_cost} |"
        )

    if not token_summary:
        lines.append("| — | — | 0 | N/A | N/A | N/A | N/A |")

    lines += [
        "",
        "## Cost Comparison: Unconstrained vs Refactory-Profile",
        "",
        "| Language | Unconstrained Cost | Refactory-Profile Cost | Delta | Delta % |",
        "|----------|--------------------|------------------------|-------|---------|",
    ]

    by_key = {}
    for s in token_summary:
        key = (s.get("language", ""), s.get("condition", ""))
        by_key[key] = s

    for lang in ("python", "rust"):
        unc = by_key.get((lang, "unconstrained"), {})
        ref = by_key.get((lang, "refactory-profile"), {})
        unc_cost = unc.get("mean_cost_usd")
        ref_cost = ref.get("mean_cost_usd")
        if unc_cost is not None and ref_cost is not None:
            delta = ref_cost - unc_cost
            pct = (delta / unc_cost * 100) if unc_cost > 0 else 0.0
            delta_str = f"+${delta:.4f}" if delta >= 0 else f"-${abs(delta):.4f}"
            pct_str = f"+{pct:.1f}%" if pct >= 0 else f"{pct:.1f}%"
            unc_str = f"${unc_cost:.4f}"
            ref_str = f"${ref_cost:.4f}"
        else:
            delta_str = "N/A"
            pct_str = "N/A"
            unc_str = f"${unc_cost:.4f}" if unc_cost is not None else "N/A"
            ref_str = f"${ref_cost:.4f}" if ref_cost is not None else "N/A"
        lines.append(
            f"| {lang.capitalize()} | {unc_str} | {ref_str} | {delta_str} | {pct_str} |"
        )

    lines += [
        "",
        "> **Note**: Costs are estimated at model pricing rates recorded at call time.",
        "> See `review/pricing.json` for the rate schedule.",
        "",
    ]
    return "\n".join(lines)


def render_comparison_table(metrics_list: list, token_summary: list) -> str:
    """Render the side-by-side comparison table (SC-005)."""
    rows = []
    for lang in ("python", "rust"):
        for cond in ("unconstrained", "refactory-profile"):
            s = aggregate_metrics(metrics_list, cond, lang)
            if s["n_runs"] == 0:
                continue
            missing_note = _fmt_missing(s["n_missing"])
            rows.append(
                {
                    "language": lang.capitalize(),
                    "condition": cond,
                    "n_runs": f"{s['n_runs']}{missing_note}",
                    "mean_ddr": f"{s['mean_ddr']:.4f}" if s["mean_ddr"] is not None else "N/A",
                    "mean_fpr": f"{s['mean_fpr']:.4f}" if s["mean_fpr"] is not None else "N/A",
                    "mean_noise_ratio": f"{s['mean_noise_ratio']:.4f}" if s["mean_noise_ratio"] is not None else "N/A",
                    "mean_cost": f"${s['mean_cost_usd']:.4f}" if s["mean_cost_usd"] is not None else "N/A",
                }
            )

    lines = [
        "# Comparison Table — Track 1 Experiments A vs B",
        "",
        "Side-by-side DDR, FPR, noise_ratio, and mean review cost",
        "across all 4 conditions (2 languages × 2 conditions).",
        "",
        "| Language | Condition | N Runs | DDR | FPR | Noise Ratio | Mean Cost (USD) |",
        "|----------|-----------|--------|-----|-----|-------------|-----------------|",
    ]
    for row in rows:
        lines.append(
            f"| {row['language']} | {row['condition']} | {row['n_runs']} "
            f"| {row['mean_ddr']} | {row['mean_fpr']} | {row['mean_noise_ratio']} "
            f"| {row['mean_cost']} |"
        )

    if not rows:
        lines.append("| — | — | 0 | N/A | N/A | N/A | N/A |")

    lines += [
        "",
        "## Interpretation",
        "",
        "- **DDR**: Higher is better (more seeded bugs found).",
        "- **FPR**: Lower is better (fewer clean regions falsely flagged).",
        "- **Noise Ratio**: Lower is better (fewer false alarms relative to misses).",
        "- **Mean Cost**: Token cost per review at model pricing rates.",
        "",
        "A positive DDR delta for `refactory-profile` vs `unconstrained` indicates the",
        "Refactory constraint *improves* reviewability for that language.",
        "",
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Generate Track 1 experiment reports from RunMetrics files."
    )
    parser.add_argument("--metrics-dir", required=True, help="Directory of RunMetrics JSON files")
    parser.add_argument(
        "--token-summary", required=True, help="Per-group token summary JSON from token_analysis.py"
    )
    parser.add_argument("--output-dir", required=True, help="Directory to write Markdown reports")
    args = parser.parse_args()

    metrics_dir = Path(args.metrics_dir)
    token_summary_path = Path(args.token_summary)
    output_dir = Path(args.output_dir)

    metrics_list = load_metrics_files(metrics_dir)
    token_summary = load_token_summary(token_summary_path)

    output_dir.mkdir(parents=True, exist_ok=True)

    reports = {
        "experiment-a.md": render_experiment_a(metrics_list),
        "experiment-b.md": render_experiment_b(metrics_list),
        "experiment-h.md": render_experiment_h(token_summary),
        "comparison-table.md": render_comparison_table(metrics_list, token_summary),
    }

    for filename, content in reports.items():
        out_path = output_dir / filename
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(content)

    print(f"Reports written to {output_dir}:")
    for filename in reports:
        print(f"  {output_dir / filename}")


if __name__ == "__main__":
    main()
