# Review Harness

Non-agentic Claude API review harness for Track 1 experiments (A and B).

## Design

The review harness makes direct Claude API calls (not Claude Code) for reproducible, single-pass code review. Key properties:

- **Non-agentic:** single-pass, no tool use, no iteration
- **Temperature 0:** deterministic output for reproducibility
- **Structured output:** JSON with identified bugs, confidence scores, and token counts
- **Thinking tokens exposed:** uses `anthropic-beta` header to get thinking token counts in the usage block

## Scripts

| Script | Purpose |
|:-------|:--------|
| `review.rb` | Run a single review pass on a MiniGit implementation |
| `batch_review.rb` | Run Experiments A/B across all conditions (Python, Constrained Python, Rust) |
| `score.rb` | Score review results against the bug catalog ground truth |

## Usage

```bash
# Single review
ruby review/review.rb --source generated/minigit-python-1-v2-bugged/ --lang python

# Batch review for Experiment A (Python vs Rust)
ruby review/batch_review.rb --experiment a --trials 20

# Batch review for Experiment B (adds constrained Python condition)
ruby review/batch_review.rb --experiment b --trials 20

# Score results against ground truth
ruby review/score.rb --results review/results/experiment-a.json --catalog bugs/catalog.json
```

## Output Format

```json
{
  "language": "python",
  "trial": 1,
  "source_dir": "generated/minigit-python-1-v2-bugged/",
  "bugs_found": [
    {
      "file": "minigit.py",
      "line": 42,
      "description": "Off-by-one in commit traversal",
      "confidence": 0.85,
      "bug_type": "off-by-one"
    }
  ],
  "false_positives": [],
  "usage": {
    "input_tokens": 12500,
    "output_tokens": 800,
    "thinking_tokens": 3200,
    "total_cost_usd": 0.05
  },
  "review_time_ms": 4500
}
```

## Metrics

- **Defect detection rate (F1):** true positives / (true positives + false negatives)
- **False positive rate:** false positives / total reported bugs
- **Review token cost:** input + output + thinking tokens per review
- **Review time:** wall-clock time per review pass
- **Thinking token ratio:** thinking_tokens / output_tokens (measures reasoning effort)
