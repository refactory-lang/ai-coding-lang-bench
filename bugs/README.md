# Bug Injection

Parameterised seeded bugs for Track 1 review experiments (Experiments A and B).

## Bug Catalog

The bug catalog (`catalog.json`) defines language-agnostic logic bugs with:
- **Difficulty rating** (1-3): how hard the bug is to detect
- **Bug type**: off-by-one, boundary condition, sort order, hash collision, index error
- **Description**: language-agnostic description of the bug
- **Injection sites**: where in the MiniGit implementation to inject each bug
- **Test-passing guarantee**: bugs are designed to pass the existing test suite but be logically wrong on untested paths

## Scripts

| Script | Purpose |
|:-------|:--------|
| `catalog.json` | Bug catalog with difficulty ratings and language-agnostic descriptions |
| `inject.rb` | Inject bugs from catalog into a MiniGit implementation |
| `verify_stealth.sh` | Verify injected bugs still pass the test suite |

## Usage

```bash
# Inject 3-5 bugs into a Python implementation
ruby bugs/inject.rb --source generated/minigit-python-1-v2/ --lang python --count 4

# Inject the same bugs into the Rust equivalent
ruby bugs/inject.rb --source generated/minigit-rust-1-v2/ --lang rust --count 4 --seed 42

# Verify bugs are stealthy (pass existing tests)
bash bugs/verify_stealth.sh generated/minigit-python-1-v2-bugged/
```

## Bug Types

| Type | Example | Difficulty |
|:-----|:--------|:-----------|
| Off-by-one | Loop boundary `< n` vs `<= n` in commit traversal | 1 |
| Boundary condition | Empty string handling in hash function | 2 |
| Sort order | Reversed comparison in log ordering | 1 |
| Hash collision | Incorrect XOR order in MiniHash edge case | 3 |
| Index error | Wrong array index in multi-file staging | 2 |
| Silent truncation | Missing newline in output for edge cases | 1 |
| State leak | Incomplete cleanup in checkout/reset | 2 |
