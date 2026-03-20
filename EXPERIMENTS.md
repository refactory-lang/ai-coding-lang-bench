# Refactory Benchmark Programme

Extension of [mame/ai-coding-lang-bench](https://github.com/mame/ai-coding-lang-bench) with 8 experiments across 3 tracks.

## Track 1: Reviewability Gap

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
