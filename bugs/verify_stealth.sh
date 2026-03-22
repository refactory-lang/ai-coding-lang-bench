#!/usr/bin/env bash
# Verify that injected bugs still pass the test suite.
#
# Usage: bash bugs/verify_stealth.sh BUGGED_DIR [TEST_SCRIPT]
#
# BUGGED_DIR    Directory containing a bugged MiniGit implementation
# TEST_SCRIPT   Test script to run (default: auto-detect v1 or v2)

set -euo pipefail

BUGGED_DIR="${1:?Usage: bash bugs/verify_stealth.sh BUGGED_DIR [TEST_SCRIPT]}"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Auto-detect test script
if [ -n "${2:-}" ]; then
  TEST_SCRIPT="$2"
elif [ -f "$BUGGED_DIR/test-v2.sh" ]; then
  TEST_SCRIPT="test-v2.sh"
elif [ -f "$BUGGED_DIR/test-v1.sh" ]; then
  TEST_SCRIPT="test-v1.sh"
else
  # Copy test script from repo root
  if [ -f "$SCRIPT_DIR/test-v2.sh" ]; then
    cp "$SCRIPT_DIR/test-v2.sh" "$BUGGED_DIR/test-v2.sh"
    TEST_SCRIPT="test-v2.sh"
  elif [ -f "$SCRIPT_DIR/test-v1.sh" ]; then
    cp "$SCRIPT_DIR/test-v1.sh" "$BUGGED_DIR/test-v1.sh"
    TEST_SCRIPT="test-v1.sh"
  else
    echo "ERROR: No test script found"
    exit 1
  fi
fi

echo "=== Bug Stealth Verification ==="
echo "Directory:   $BUGGED_DIR"
echo "Test script: $TEST_SCRIPT"
echo

# Check for manifest
MANIFEST="$BUGGED_DIR/.bug-manifest.json"
if [ -f "$MANIFEST" ]; then
  echo "Bug manifest found:"
  python3 -c "
import json, sys
m = json.load(open('$MANIFEST'))
for b in m.get('injected', []):
    print(f\"  {b['id']} ({b['type']}, difficulty {b['difficulty']})\")
if m.get('skipped'):
    print(f\"  Skipped: {len(m['skipped'])} bugs\")
" 2>/dev/null || echo "  (could not parse manifest)"
  echo
fi

# Build if needed
cd "$BUGGED_DIR"
if [ -f Makefile ] || [ -f makefile ]; then
  echo "Building..."
  make -s 2>/dev/null || true
fi
if [ -f build.sh ]; then
  echo "Building (build.sh)..."
  bash build.sh 2>/dev/null || true
fi
chmod +x minigit 2>/dev/null || true

# Run tests
echo "Running tests..."
echo

OUTPUT=$(bash "$TEST_SCRIPT" 2>&1) || true

echo "$OUTPUT"
echo

# Extract results
PASSED=$(echo "$OUTPUT" | grep -o 'PASSED: [0-9]*' | awk '{print $2}')
FAILED=$(echo "$OUTPUT" | grep -o 'FAILED: [0-9]*' | awk '{print $2}')

PASSED="${PASSED:-0}"
FAILED="${FAILED:-0}"

echo "=== Stealth Verification Result ==="
if [ "$FAILED" -eq 0 ] && [ "$PASSED" -gt 0 ]; then
  echo "STEALTH: PASS — All $PASSED tests pass despite injected bugs"
  echo "Bugs are properly stealthy (not caught by existing test suite)"
  exit 0
else
  echo "STEALTH: FAIL — $FAILED test(s) failed"
  echo "Some injected bugs are caught by the test suite and need refinement"
  exit 1
fi
