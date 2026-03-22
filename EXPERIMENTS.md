# Refactory Benchmark Programme

Extension of [mame/ai-coding-lang-bench](https://github.com/mame/ai-coding-lang-bench) with 7 experiments across 3 tracks measuring the reviewability gap, pipeline economics, and thinking clusters for [Refactory](https://github.com/refactory-lang).

## Track 1: Reviewability Gap (the missing evidence)

The central Refactory claim — that humans and AI review Python more effectively than Rust — has no quantitative evidence. This track produces it.

### Running Track 1

Run the full Track 1 pipeline (inject → review → score → report) with:

```bash
ruby review/batch_review.rb --experiment a --trials 20
ruby review/score.rb --results review/results/experiment-a
```

For Experiment B (adds constrained Python condition):

```bash
ruby review/batch_review.rb --experiment b --trials 20
ruby review/score.rb --results review/results/experiment-b
```

### Experiment A — Seeded-Bug Review Accuracy

For each of the 20 successful Python and Rust runs from the original benchmark, inject 3-5 seeded logic bugs (off-by-one errors, incorrect boundary conditions, wrong sort order — bugs that pass the test suite but are logically wrong on untested paths). Ask Claude (non-agentic, single-pass, no tool use) to review the code and identify bugs. Measure defect detection rate, false positive rate, review token cost, and time — stratified by bug type. The same bugs appear in both languages, controlling for functional equivalence. This directly tests F1.

- **Conditions:** Python, Rust (paired by functional equivalence)
- **Bug types:** off-by-one, boundary condition, sort order, hash collision, index error
- **Metrics:** defect detection rate (F1), false positive rate, review tokens (input/output/thinking), review time
- **Controls:** same bugs in both languages, same model, temperature 0, single-pass

> **Review token economics** are measured as part of this experiment — the review harness captures full token breakdowns per review pass (input, output, thinking tokens). This means review token economics (do Python reviews consume fewer thinking tokens than Rust reviews?) are measured here, not as a separate experiment.

### Experiment B — Constrained Python Review

Repeat Experiment A with a third condition: the same bugs seeded into Python written under the Refactory profile (frozen dataclasses, Result types, full PEP 484 annotations). This tests whether the constrained subset improves or degrades reviewability relative to vanilla Python.

- **Conditions:** Vanilla Python, Constrained Python (Python-as-Rust profile), Rust
- **Key question:** If constrained Python is harder to review than vanilla Python (because the profile constructs are unfamiliar), the "review happens on Python source" argument weakens
- **Metrics:** same as Experiment A, with pairwise comparisons across all three conditions

## Track 2: Pipeline Economics

### Experiment C — Constrained Python Generation Cost

Add a "Python-as-Rust" condition to the generation benchmark: Claude Code generates Python under the Refactory profile (system prompt enforces frozen dataclasses, Result types, annotations, no exceptions). 20 trials. Compare generation cost/time/turns against vanilla Python, Python/mypy, and Rust. This measures the profile tax on generation — the delta between vanilla Python ($0.38) and constrained Python.

- **New language entry:** `python/refactory` with profile-enforcing `extra_prompt`
- **Trials:** 20
- **Metrics:** wall-clock time, cost, turns, input/output tokens, pass rate
- **Comparison baselines:** vanilla Python ($0.38), Python/mypy ($0.57), Rust ($0.54)

### Experiment D — Normalize + Type Infer Pipeline Cost

Take the 20 vanilla Python outputs from the original benchmark and run the Refactory normalization + Type Infer (Step 4) pipeline: deterministic transforms (jssg), then the hybrid Type Infer step — JSSG transforms using Codemod semantic analysis (ruff) to identify unannotated sites, pyright as inference oracle, refactory-annotate for insertion, mypy --strict for verification. Measure wall-clock time per sub-step (jssg identification, pyright inference, annotation insertion, mypy verification), transform success rate, mypy pass rate, and total cost. Compare against the Python/mypy condition ($0.57) — hypothesis: deterministic hybrid pipeline < agentic mypy iteration.

- **Dependencies:** Milestone 0.5 (shadow libraries), Refactory pipeline tooling
- **Metrics:** wall-clock time per sub-step, transform success rate, mypy pass rate, total cost

### Experiment E — JS-to-TS Conversion Cost

For each of the 20 successful JavaScript runs, apply the js2ts pipeline (tsgo inference + annotation insertion + tsgo --strict verification). Measure conversion time, success rate, tsgo pass rate, and total pipeline cost (JS generation $0.39 + conversion). Compare against direct TS generation ($0.62). Tests F3.

- **Dependencies:** tsgo (`@typescript/native-preview`), js2ts tool
- **Metrics:** conversion time, success rate, tsgo pass rate, total pipeline cost
- **Comparison:** direct TS generation ($0.62) vs JS generation ($0.39) + conversion

### Experiment F — JS-to-TS-to-Rust Pipeline

If Experiment E validates, extend: take the js2ts output and run it through the Refactory TS-to-Rust pipeline (Normalize-Det -> S1 -> S2 -> S3 -> Verify). Compare against direct TS-to-Rust. The key question: does converted TS trigger more Stage 3 (LLM) fallbacks than agent-generated TS? If the conversion produces annotations that are technically correct but structurally different from what the S1/S2 transforms expect, the generation savings may be consumed by translation costs.

- **Dependencies:** Experiment E results, Refactory TS-to-Rust pipeline (Milestone 1 Track B)
- **Metrics:** Stage 3 stub count, compilation success rate, total pipeline cost

## Track 3: Thinking-Cluster Investigation

### Experiment G — Extended Language Matrix

The three thinking-stability clusters (stable: Python/JS/Ruby/Python-mypy; moderate: Java/Go/TS; volatile: Rust/Haskell/OCaml/Perl) are empirically clear but causally underdetermined. TypeScript (bolt-on typing, high familiarity) sits in the moderate cluster alongside Java (native typing, high familiarity) rather than in the stable cluster with Python/mypy (bolt-on typing, high familiarity). This experiment adds languages to stress-test hypotheses:

| Language | Type System | Familiarity | Hypothesis Tested |
|:---------|:------------|:------------|:------------------|
| **PHP** | Dynamic, gradual typing via PHPStan | High (web) | **Key test of the TS anomaly.** If PHP + bolt-on typing (PHPStan strict) behaves like Python/mypy (stable), the TS anomaly is TS-specific. If PHP + PHPStan lands in the moderate cluster like TS, bolt-on typing on languages with complex ecosystems may inherently raise variance. |
| Kotlin | Native static, JVM | High (Android) | If Kotlin ~ Java (moderate), native static typing raises variance regardless of language design quality |
| C# | Native static, .NET | High (enterprise) | Same test as Kotlin; different ecosystem |
| Dart | Native static, Flutter | Moderate | Tests whether Dart's simpler type system (no checked exceptions, no complex generics) lands in stable or moderate |
| Swift | Native static, Apple | Moderate-High | Strong type inference, protocol-oriented — does protocol focus help or hurt? |

20 trials per language on the same mini-git task. PHP is the highest-priority addition — it directly addresses the TypeScript anomaly that currently blocks a clean explanatory model.

## Configuration Changes from Upstream

The original benchmark uses `--dangerously-skip-permissions` and runs Claude Code with default settings. The fork makes three configuration changes:

1. **Expose thinking tokens.** Configure Claude Code to emit `output_tokens` broken down into `thinking_tokens` and `visible_tokens` in the JSON log `result` entries. If the Claude Code CLI supports flags that expose the `thinking` usage field separately, use them. Otherwise, patch `benchmark.rb` to make API calls that request thinking token counts in the usage block. This replaces the chars/output-token proxy with actual measurements.

2. **Record per-turn token breakdowns.** The upstream `result` entry aggregates tokens across all turns. The fork additionally logs per-turn usage (input_tokens, output_tokens, thinking_tokens, cache_read, cache_creation) so that token accumulation curves can be plotted — showing how context growth compounds across turns. This enables analysis of whether the iteration tax is linear or superlinear in turn count.

3. **Pin model version.** The upstream used `claude-opus-4-6` as of March 2026. The fork pins to a specific model snapshot (e.g., `claude-opus-4-6-20260301`) to ensure reproducibility across experiment tracks that may run weeks apart.

## Infrastructure

The fork inherits the benchmark harness (`benchmark.rb`), test infrastructure (`test-v1.sh`, `test-v2.sh`), and spec files. New components:

| Component | Directory | Purpose |
|:----------|:----------|:--------|
| Token analysis scripts | `analysis/` | Extract token breakdowns from Claude Code JSON logs, compute per-language aggregates, thinking-stability metrics (CV, heavy-thinking run counts), and statistical tests |
| Bug injection scripts | `bugs/` | Parameterised seeded bugs for review experiments (Track 1). Bug catalog with difficulty ratings and language-agnostic descriptions |
| Review harness | `review/` | Non-agentic Claude API calls (single-pass, no tool use, temperature 0) for reproducible review experiments. Outputs structured JSON with identified bugs, confidence scores, and token counts |

## Timeline and Dependencies

| Track | Experiments | Effort | Dependencies | Parallel? |
|:------|:-----------|:-------|:-------------|:----------|
| Track 1 (Review) | A, B | 1.5 weeks | Bug injection scripts, review harness | Can start immediately |
| Track 2 (Pipeline) | C, D, E, F | 2.5 weeks | Tier 0 + Type Infer implementation (hybrid), js2ts tool | D depends on Milestone 0.5 (shadow libraries); E/F can start with just tsgo |
| Track 3 (Clusters) | G | 1 week setup + 2 weeks execution | Language toolchain installs, compute budget | Can start immediately |

Total: ~5 weeks serialised, ~3 weeks parallel. Track 1 is highest priority (produces the missing reviewability evidence). Track 3 is lowest priority for Refactory but has the highest standalone publication value.

## Falsifiability Conditions

**F1. Reviewability gap.** If Claude's defect detection rate on Rust code is equal to or higher than on equivalent Python code (controlling for bug type and code complexity), the reviewability gap claim is falsified. Threshold: non-significant difference (p > 0.05) across 40+ paired trials.

**F3. JS-to-TS pipeline economics.** If the JS-to-TS conversion pipeline produces TypeScript that tsgo --strict rejects in more than 10% of files from agent-generated JavaScript, or if the total pipeline cost (JS generation + conversion) exceeds direct TS generation cost, the "generate cheap, convert deterministically" thesis is falsified for the JS-to-TS case.

**F4. Generation gap closure.** If future benchmarks show that Rust generation cost drops below Python generation cost (e.g., due to Rust-specific training improvements), the economic argument for translating from Python collapses. The reviewability argument would still hold, but the cost motivation would not.
