# Analysis

Token analysis scripts for the Refactory Benchmark Programme.

## Scripts

| Script | Purpose | Experiments |
|:-------|:--------|:------------|
| `token_analysis.rb` | Extract token breakdowns from Claude Code JSON logs, compute per-language aggregates, thinking-stability metrics (CV, heavy-thinking run counts), and statistical tests | All |
| `thinking_clusters.rb` | Compute visible-chars-per-output-token ratios, cluster languages by thinking stability, test hypotheses about type systems and familiarity | G |
| `per_turn_curves.rb` | Plot token accumulation curves from per-turn breakdowns, analyze whether iteration tax is linear or superlinear in turn count | All |

## Usage

```bash
ruby analysis/token_analysis.rb results/results.json
ruby analysis/thinking_clusters.rb results/results.json
ruby analysis/per_turn_curves.rb results/results.json
```

## Metrics

- **Thinking stability (CV):** Coefficient of variation of visible-chars-per-output-token across trials for each language
- **Heavy-thinking runs:** Trials where thinking overhead exceeds 2 standard deviations from the language mean
- **Iteration tax:** Ratio of input tokens to output tokens, decomposed by turn number
- **Per-turn token accumulation:** Input tokens, output tokens, thinking tokens, cache read/creation per turn
