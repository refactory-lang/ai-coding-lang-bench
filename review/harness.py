#!/usr/bin/env python3
"""
review/harness.py — Review Harness for Track 1 Experiments A and B.

Submits a seeded MiniGit implementation to the Anthropic Claude API as a
single non-agentic review call and saves the structured response.

Usage:
    python3 review/harness.py \\
        --seeded-dir PATH \\
        --manifest-path PATH \\
        --output-path PATH \\
        --condition CONDITION \\
        [--model MODEL] \\
        [--max-tokens INT] \\
        [--api-key-env VAR]
"""

import argparse
import datetime
import json
import os
import re
import sys
import time
from pathlib import Path


PROMPTS_DIR = Path(__file__).parent / "prompts"
PRICING_PATH = Path(__file__).parent / "pricing.json"
DEFAULT_MODEL = "claude-opus-4.6"
DEFAULT_MAX_TOKENS = 4096
DEFAULT_API_KEY_ENV = "ANTHROPIC_API_KEY"
MAX_RETRIES = 3
BACKOFF_SECONDS = [2, 4, 8]
# Anthropic exception class names that indicate a terminal error (no retry).
TERMINAL_ERROR_NAMES = frozenset({"AuthenticationError", "InvalidRequestError", "PermissionDeniedError"})
# Anthropic exception class names (and message substrings) for transient/retryable errors.
TRANSIENT_ERROR_NAMES = frozenset({
    "RateLimitError", "APIConnectionError", "APITimeoutError",
    "APIStatusError", "InternalServerError", "ServiceUnavailableError",
    "OverloadedError", "ConnectionError", "TimeoutError",
})
TRANSIENT_ERROR_KEYWORDS = ("rate limit", "timeout", "connection", "503", "529", "overload")


def _save_result_and_exit(result: dict, output_path: Path, exit_code: int = 1) -> None:
    """Write result JSON to disk and terminate the process."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)
    sys.exit(exit_code)


def load_prompt(condition: str) -> str:
    """Load the system prompt for the given condition."""
    prompt_file = PROMPTS_DIR / f"{condition}.txt"
    if not prompt_file.exists():
        print(
            f"Error: prompt file not found: {prompt_file}",
            file=sys.stderr,
        )
        sys.exit(1)
    return prompt_file.read_text(encoding="utf-8").strip()


def load_pricing(model: str) -> tuple:
    """
    Load pricing for the given model.
    Returns (input_per_1k, output_per_1k) in USD.
    """
    if not PRICING_PATH.exists():
        return (0.015, 0.075)  # fallback defaults for claude-opus-4.6
    with open(PRICING_PATH, encoding="utf-8") as fh:
        pricing = json.load(fh)
    if model not in pricing:
        # Use first available model's pricing as fallback
        first = next(iter(pricing.values()))
        return (first["input_per_1k"], first["output_per_1k"])
    entry = pricing[model]
    return (entry["input_per_1k"], entry["output_per_1k"])


def load_manifest(manifest_path: Path) -> dict:
    """Load and return the BugManifest JSON."""
    with open(manifest_path, encoding="utf-8") as fh:
        return json.load(fh)


def build_user_prompt(seeded_dir: Path) -> str:
    """
    Concatenate all source files alphabetically with ### filename headers.
    Returns the assembled user prompt text.
    """
    # Collect source files
    extensions = {".py", ".rs", ".c", ".cpp", ".h", ".js", ".ts", ".go", ".java", ".rb"}
    source_files = []
    for f in sorted(seeded_dir.rglob("*")):
        if f.is_file() and f.suffix in extensions:
            # Exclude hidden files and common non-source files
            rel = f.relative_to(seeded_dir)
            parts = rel.parts
            if not any(p.startswith(".") for p in parts):
                source_files.append(f)

    if not source_files:
        # Fallback: include all non-binary files
        for f in sorted(seeded_dir.rglob("*")):
            if f.is_file() and not f.name.startswith("."):
                try:
                    f.read_text(encoding="utf-8")
                    source_files.append(f)
                except (UnicodeDecodeError, PermissionError):
                    pass

    parts = []
    for src_file in source_files:
        rel_path = src_file.relative_to(seeded_dir)
        try:
            content = src_file.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        parts.append(f"### {rel_path}\n\n```\n{content}\n```")

    user_text = "\n\n".join(parts)
    user_text += (
        "\n\nPlease review the code above for logic errors. "
        "Output only findings in the required format."
    )
    return user_text


def parse_findings(raw_text: str) -> list:
    """
    Parse structured findings from the reviewer's raw text.

    Looks for patterns like:
        **Finding N**: file_path, lines start–end
        One-sentence description.
    """
    findings = []
    # Pattern: **Finding N**: file_path, lines X–Y (or line X or lines X-Y)
    pattern = re.compile(
        r"\*\*Finding\s+(\d+)\*\*\s*:?\s*"
        r"([^\n,]+?)\s*,\s*lines?\s*(\d+)(?:[–\-](\d+))?"
        r"\s*\n([^\n*]+)",
        re.IGNORECASE,
    )
    for m in pattern.finditer(raw_text):
        finding_num = m.group(1)
        file_path = m.group(2).strip()
        line_start = int(m.group(3))
        line_end = int(m.group(4)) if m.group(4) else line_start
        description = m.group(5).strip()
        findings.append(
            {
                "finding_id": f"F{finding_num}",
                "file_path": file_path,
                "line_start": line_start,
                "line_end": line_end,
                "description": description,
            }
        )

    # Also try a looser pattern without line numbers
    if not findings:
        pattern2 = re.compile(
            r"\*\*Finding\s+(\d+)\*\*\s*:?\s*([^\n]+)\n([^\n*]+)",
            re.IGNORECASE,
        )
        for m in pattern2.finditer(raw_text):
            finding_num = m.group(1)
            header = m.group(2).strip()
            description = m.group(3).strip()
            # Try to extract file and line from header
            file_path = header
            line_start = None
            line_end = None
            line_m = re.search(r"lines?\s*(\d+)(?:[–\-](\d+))?", header, re.IGNORECASE)
            if line_m:
                line_start = int(line_m.group(1))
                line_end = int(line_m.group(2)) if line_m.group(2) else line_start
                file_path = header[: line_m.start()].strip().rstrip(",").strip()
            findings.append(
                {
                    "finding_id": f"F{finding_num}",
                    "file_path": file_path,
                    "line_start": line_start,
                    "line_end": line_end,
                    "description": description,
                }
            )

    return findings


def call_api(client, model: str, system_prompt: str, user_prompt: str, max_tokens: int) -> dict:
    """
    Make a single non-agentic API call to Anthropic.

    Returns dict with keys: raw_text, input_tokens, output_tokens, finish_reason.
    May raise anthropic exceptions on failure.
    """
    response = client.messages.create(
        model=model,
        max_tokens=max_tokens,
        system=system_prompt,
        messages=[{"role": "user", "content": user_prompt}],
        temperature=0,
    )
    raw_text = ""
    if response.content:
        raw_text = response.content[0].text if hasattr(response.content[0], "text") else ""

    return {
        "raw_text": raw_text,
        "input_tokens": response.usage.input_tokens,
        "output_tokens": response.usage.output_tokens,
        "finish_reason": response.stop_reason,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Submit a seeded MiniGit implementation to Anthropic Claude for review."
    )
    parser.add_argument("--seeded-dir", required=True, help="Path to seeded implementation")
    parser.add_argument("--manifest-path", required=True, help="Path to BugManifest JSON")
    parser.add_argument("--output-path", required=True, help="Path to write ReviewResponse JSON")
    parser.add_argument(
        "--condition",
        required=True,
        choices=["unconstrained", "refactory-profile"],
        help="Reviewer condition",
    )
    parser.add_argument(
        "--model", default=DEFAULT_MODEL, help=f"Anthropic model (default: {DEFAULT_MODEL})"
    )
    parser.add_argument(
        "--max-tokens", type=int, default=DEFAULT_MAX_TOKENS, help="Max output tokens"
    )
    parser.add_argument(
        "--api-key-env",
        default=DEFAULT_API_KEY_ENV,
        help=f"Env var holding API key (default: {DEFAULT_API_KEY_ENV})",
    )
    args = parser.parse_args()

    seeded_dir = Path(args.seeded_dir)
    manifest_path = Path(args.manifest_path)
    output_path = Path(args.output_path)

    if not seeded_dir.exists():
        print(f"Error: seeded-dir '{seeded_dir}' does not exist.", file=sys.stderr)
        sys.exit(1)
    if not manifest_path.exists():
        print(f"Error: manifest-path '{manifest_path}' does not exist.", file=sys.stderr)
        sys.exit(1)

    # Load manifest for metadata
    manifest = load_manifest(manifest_path)
    run_id = manifest["run_id"]

    # Load prompts and pricing
    system_prompt = load_prompt(args.condition)
    user_prompt = build_user_prompt(seeded_dir)
    price_in, price_out = load_pricing(args.model)

    # Import anthropic (optional dependency — only required for real runs)
    try:
        import anthropic
    except ImportError:
        print(
            "Error: 'anthropic' package is not installed. "
            "Run: pip install anthropic",
            file=sys.stderr,
        )
        sys.exit(1)

    api_key = os.environ.get(args.api_key_env, "")
    if not api_key:
        print(
            f"Error: {args.api_key_env} environment variable is not set.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Build result skeleton
    result = {
        "run_id": run_id,
        "condition": args.condition,
        "model": args.model,
        "reviewed_at": None,
        "input_tokens": 0,
        "output_tokens": 0,
        "finish_reason": None,
        "price_per_1k_input_usd": price_in,
        "price_per_1k_output_usd": price_out,
        "estimated_cost_usd": 0.0,
        "raw_text": "",
        "findings": [],
        "missing_data": False,
        "missing_data_reason": None,
        "retry_count": 0,
    }

    # Try to create the client — catch auth errors immediately
    try:
        client = anthropic.Anthropic(api_key=api_key)
    except Exception as exc:
        result["missing_data"] = True
        result["missing_data_reason"] = f"Client creation failed: {exc}"
        result["reviewed_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        _save_result_and_exit(result, output_path)

    # Execute API call with retry policy
    last_error = None
    for attempt in range(MAX_RETRIES + 1):
        try:
            api_result = call_api(client, args.model, system_prompt, user_prompt, args.max_tokens)
            result["input_tokens"] = api_result["input_tokens"]
            result["output_tokens"] = api_result["output_tokens"]
            result["finish_reason"] = api_result["finish_reason"]
            result["raw_text"] = api_result["raw_text"]
            result["reviewed_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            result["retry_count"] = attempt
            result["estimated_cost_usd"] = round(
                (result["input_tokens"] / 1000) * price_in
                + (result["output_tokens"] / 1000) * price_out,
                6,
            )
            result["findings"] = parse_findings(result["raw_text"])
            break

        except Exception as exc:
            exc_type = type(exc).__name__
            last_error = str(exc)

            # Terminal errors (auth, invalid request) — no retry
            is_terminal = exc_type in TERMINAL_ERROR_NAMES or "authentication" in str(exc).lower()

            if is_terminal:
                result["missing_data"] = True
                result["missing_data_reason"] = f"{exc_type}: {exc}"
                result["reviewed_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                result["retry_count"] = attempt
                _save_result_and_exit(result, output_path)

            # Non-terminal: only treat as retryable if it looks like a transient
            # API/network error.  Application errors (AttributeError, KeyError…)
            # are re-raised so they propagate rather than silently becoming missing data.
            is_transient = exc_type in TRANSIENT_ERROR_NAMES or any(
                kw in str(exc).lower() for kw in TRANSIENT_ERROR_KEYWORDS
            )
            if not is_transient:
                raise  # propagate unexpected application-level errors

            # Retryable transient error
            if attempt < MAX_RETRIES:
                backoff = BACKOFF_SECONDS[attempt] if attempt < len(BACKOFF_SECONDS) else 8
                print(
                    f"Attempt {attempt + 1} failed ({exc_type}): {exc}. "
                    f"Retrying in {backoff}s...",
                    file=sys.stderr,
                )
                time.sleep(backoff)
            else:
                # All retries exhausted
                result["missing_data"] = True
                result["missing_data_reason"] = f"All {MAX_RETRIES} retries exhausted. Last error: {exc}"
                result["reviewed_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                result["retry_count"] = attempt
                print(
                    f"Review {run_id} [{args.condition}]: MISSING DATA after {MAX_RETRIES} retries",
                    file=sys.stderr,
                )
                _save_result_and_exit(result, output_path, exit_code=2)

    # Success path — write output
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)

    print(
        f"Review complete: {run_id} [{args.condition}] — "
        f"{result['input_tokens']} in / {result['output_tokens']} out"
    )


if __name__ == "__main__":
    main()
