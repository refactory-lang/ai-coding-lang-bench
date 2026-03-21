# Refactory Benchmark Programme

Extension of [mame/ai-coding-lang-bench](https://github.com/mame/ai-coding-lang-bench) with 8 experiments across 3 tracks.

## Track 1: Reviewability Gap

### Running Track 1

Run the full Track 1 pipeline (inject → review → score → analyse → report) with:

```bash
bash run-track1.sh --condition both --model claude-opus-4.6
```

For a dry-run that prints all commands without making API calls:

```bash
bash run-track1.sh --dry-run
```

See [`specs/004-track-1-reviewability/quickstart.md`](specs/004-track-1-reviewability/quickstart.md)
for the step-by-step reproduction guide.

**Expected runtime**: ~5 min for injection + scoring, ~15–20 min for all 78 API calls.  
**Estimated cost**: ~$5–$8 at claude-opus-4.6 2026-03 pricing (minimum ~$4, up to ~$10
depending on implementation size).

### Experiment A — Seeded-Bug Review Accuracy
- Inject 3-5 seeded logic bugs into successful Python and Rust runs
- Non-agentic Claude review (single-pass, no tool use)
- Measure: defect detection rate, false positive rate, review token cost
- Tests falsifiability condition F1

### Experiment B — Constrained Python Review
- Same as A but adds Python-as-Rust profile condition
- Tests whether constrained subset improves or degrades reviewability

### Experiment H — Review Token Economics
- Token-level analysis of review passes from Experiments A and B
- Produces cost evidence for the reviewability gap

## Track 2: Pipeline Economics

### Experiment C — Constrained Python Generation Cost
- Generate Python under Refactory profile, 20 trials
- Compare against vanilla Python ($0.38), Python/mypy ($0.57), Rust
- Measures the profile tax on generation

### Experiment D — Normalize + Type Infer Pipeline Cost
- Run Refactory pipeline on vanilla Python outputs
- Measure: wall-clock time per sub-step, transform success rate, mypy pass rate
- Compare against Python/mypy agentic iteration
- Depends on Milestone 0.5 (shadow libraries)

### Experiment E — JS→TS Conversion Cost
- Apply js2ts pipeline to successful JS runs
- Measure: conversion time, success rate, tsgo pass rate, total pipeline cost
- Tests falsifiability condition F3

### Experiment F — JS→TS→Rust Pipeline
- Extend E through TS→Rust pipeline
- Key question: does converted TS trigger more Stage 3 fallbacks than agent-generated TS?

## Track 3: Thinking-Cluster Investigation

### Experiment G — Extended Language Matrix
- Add PHP, Kotlin, C#, Dart, Swift (20 trials each)
- PHP is highest priority — tests the TypeScript anomaly
- Tests whether bolt-on typing on complex ecosystems raises variance

## Timeline

| Track | Experiments | Effort | Dependencies |
|:------|:-----------|:------|:-----------|
| Track 1 (Review) | A, B, H | 2 weeks | Bug injection scripts, review harness |
| Track 2 (Pipeline) | C, D, E, F | 2.5 weeks | Milestone 0.5, js2ts tool |
| Track 3 (Clusters) | G | 1 week setup + 2 weeks execution | Language toolchains |

Total: ~5 weeks serialised, ~3 weeks parallel.
