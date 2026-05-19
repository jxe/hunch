#!/usr/bin/env bash
# Run Periphery against both targets and emit only the warnings worth
# triaging. @Test-function "is unused" warnings from the test bundles
# are stripped — Periphery doesn't recognize Swift Testing roots, so
# every @Test flags as unused. Real findings still surface; the
# documented known-FP set listed in SKILL.md is what's left.
#
# Run from the repo root. Outputs two sections, one per scan.

set -u
cd "$(git rev-parse --show-toplevel)"

echo "=== Hunch app target ==="
periphery scan 2>&1 | grep "warning:" | grep -v "^App/Tests/"
echo ""
echo "=== Editor SPM package ==="
( cd Packages/Editor && periphery scan 2>&1 | grep "warning:" | grep -v "^Tests/EditorTests/" )
