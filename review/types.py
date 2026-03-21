"""
review/types.py — TypedDict definitions for Track 1 core data types.

These classes serve as structural contracts for the five key data types.
All pipeline tools produce and consume plain dicts; these TypedDicts
document the expected field shapes and enable static analysis (mypy/pyright).

Usage example::

    from review.types import RunMetrics
    metrics: RunMetrics = score(manifest, review)
"""

from __future__ import annotations

from typing import Optional, TypedDict


class InjectionRecord(TypedDict):
    """Single injected-bug record within a BugManifest."""

    id: str
    category: str
    language: str
    file_path: str
    line_number: int
    original_line: str
    injected_line: str
    description: str


class BugManifest(TypedDict):
    """Output of bugs/inject.py — describes what was injected and where."""

    run_id: str
    language: str
    trial: int
    version: str
    seed: int
    seeded_dir: str
    injected_at: str
    bugs: list  # list[InjectionRecord]


class ReviewResponse(TypedDict):
    """Output of review/harness.py — single API review call result."""

    run_id: str
    condition: str
    model: str
    reviewed_at: Optional[str]
    input_tokens: int
    output_tokens: int
    finish_reason: Optional[str]
    price_per_1k_input_usd: float
    price_per_1k_output_usd: float
    estimated_cost_usd: float
    raw_text: str
    findings: list  # list of finding dicts
    missing_data: bool
    missing_data_reason: Optional[str]
    retry_count: int


class RunMetrics(TypedDict):
    """Output of review/score.py — per-run accuracy and cost metrics.

    All count/metric fields are ``None`` when ``missing_data`` is ``True``.

    ``noise_ratio`` is also ``None`` when the denominator ``FP + FN == 0``
    (i.e., a perfect detector with no false alarms), which is semantically
    distinct from a zero-noise ratio produced by a silent reviewer
    (``FP=0, FN>0``).
    """

    run_id: str
    condition: str
    language: str
    trial: int
    version: str
    total_bugs: int
    tp_count: Optional[int]
    fp_count: Optional[int]
    fn_count: Optional[int]
    tn_count: Optional[int]
    ddr: Optional[float]
    fpr: Optional[float]
    noise_ratio: Optional[float]   # None when FP+FN==0 (undefined, not zero)
    input_tokens: int
    output_tokens: int
    estimated_cost_usd: float
    missing_data: bool


class ExperimentSummary(TypedDict):
    """Aggregated summary for one (condition, language) group.

    Mean/std metric fields are ``None`` when all runs in the group are
    ``missing_data: true`` (no valid data — must not be displayed as 0).
    """

    condition: str
    language: str
    n_runs: int
    n_missing: int
    mean_ddr: Optional[float]
    std_ddr: Optional[float]
    mean_fpr: Optional[float]
    std_fpr: Optional[float]
    mean_noise_ratio: Optional[float]
    std_noise_ratio: Optional[float]
    mean_cost_usd: Optional[float]
    std_cost_usd: Optional[float]


class TokenGroupSummary(TypedDict):
    """Aggregated token/cost summary per (language, condition) group.

    Produced by analysis/token_analysis.py.  Mean fields are ``None``
    when all runs in the group are missing data (no valid token records).
    """

    condition: str
    language: str
    n_runs: int
    n_missing: int
    mean_input_tokens: Optional[float]
    std_input_tokens: Optional[float]
    mean_output_tokens: Optional[float]
    std_output_tokens: Optional[float]
    mean_cost_usd: Optional[float]
    std_cost_usd: Optional[float]
    total_input_tokens: int
    total_output_tokens: int
    total_cost_usd: float
