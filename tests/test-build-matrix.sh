#!/bin/bash
#
# test-build-matrix.sh: Manual test runner for build-matrix.
#
# Tests the batch-building logic with various branch counts, including the
# exact edge case (count exactly divisible by batch size) that caused the
# Feb 2026 production failure.
#
# Usage:
#   ./tests/test-build-matrix.sh
#   ./tests/test-build-matrix.sh --verbose   # print full matrix JSON for each case
#
# Requirements: jq, bash 4+

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_MATRIX="${SCRIPT_DIR}/../build-matrix"

VERBOSE=false
if [[ "${1}" == "--verbose" ]]; then
    VERBOSE=true
fi

# ── helpers ──────────────────────────────────────────────────────────────────

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; ((PASS+=1)); }
fail() { echo "  FAIL: $*"; ((FAIL+=1)); }

# Generate N unique branch names
gen_branches() {
    local n="$1"
    local i
    for ((i=1; i<=n; i++)); do
        echo "feature/branch-${i}"
    done
}

# Run build-matrix with the given branch list and batch size.
# Prints the compact matrix JSON on stdout; all build-matrix output goes to stderr.
run_build_matrix() {
    local branch_list="$1"
    local batch_size="${2:-100}"
    local tmpout
    tmpout=$(mktemp)

    # GITHUB_OUTPUT must be exported before the pipeline so the subprocess
    # (build-matrix) inherits it. Inline assignment before a pipeline only
    # applies to the first command in the pipeline, not to subsequent ones.
    export GITHUB_OUTPUT="$tmpout"
    printf '%s\n' "$branch_list" \
        | "$BUILD_MATRIX" --batch-size "$batch_size" >/dev/null 2>&1 || {
            echo ""   # return empty string on failure
            rm -f "$tmpout"
            return 1
        }
    unset GITHUB_OUTPUT

    # Extract the matrix JSON value from "matrix=<json>"
    local json
    json=$(grep '^matrix=' "$tmpout" | head -1 | sed 's/^matrix=//')
    rm -f "$tmpout"
    printf '%s' "$json"
}

assert_batch_count() {
    local label="$1"
    local json="$2"
    local expected_batches="$3"
    local actual_batches
    actual_batches=$(echo "$json" | jq '.include | length')
    if [[ "$actual_batches" -eq "$expected_batches" ]]; then
        pass "$label — expected ${expected_batches} batches, got ${actual_batches}"
    else
        fail "$label — expected ${expected_batches} batches, got ${actual_batches}"
    fi
}

assert_total_branch_count() {
    local label="$1"
    local json="$2"
    local expected_total="$3"
    local actual_total
    actual_total=$(echo "$json" | jq '[.include[].count] | add // 0')
    if [[ "$actual_total" -eq "$expected_total" ]]; then
        pass "$label — expected total branch count ${expected_total}, got ${actual_total}"
    else
        fail "$label — expected total branch count ${expected_total}, got ${actual_total}"
    fi
}

assert_no_empty_batches() {
    local label="$1"
    local json="$2"
    local empty_batches
    empty_batches=$(echo "$json" | jq '[.include[] | select(.count == 0 or .branches == "")] | length')
    if [[ "$empty_batches" -eq 0 ]]; then
        pass "$label — no empty batches"
    else
        fail "$label — found ${empty_batches} empty batch(es)"
    fi
}

assert_max_batch_size() {
    local label="$1"
    local json="$2"
    local batch_size="$3"
    local oversized
    oversized=$(echo "$json" | jq --argjson max "$batch_size" '[.include[] | select(.count > $max)] | length')
    if [[ "$oversized" -eq 0 ]]; then
        pass "$label — all batches are within batch size ${batch_size}"
    else
        fail "$label — found ${oversized} batch(es) exceeding batch size ${batch_size}"
    fi
}

assert_branch_count_matches_list() {
    local label="$1"
    local json="$2"
    local expected_total="$3"
    # Verify that count fields actually match the number of branch names in each batch
    local mismatched
    mismatched=$(echo "$json" | jq '
        [ .include[] |
          . as $b |
          ($b.branches | split(" ") | length) as $actual |
          select($actual != $b.count)
        ] | length
    ')
    if [[ "$mismatched" -eq 0 ]]; then
        pass "$label — count fields match actual branch name counts"
    else
        fail "$label — ${mismatched} batch(es) have count fields that don't match branch name counts"
    fi
}

run_case() {
    local label="$1"
    local branch_count="$2"
    local batch_size="${3:-100}"

    echo ""
    echo "── ${label} (${branch_count} branches, batch size ${batch_size}) ──"

    local branches
    branches=$(gen_branches "$branch_count")

    local json
    json=$(run_build_matrix "$branches" "$batch_size")

    if [[ -z "$json" ]]; then
        fail "$label — build-matrix produced no output"
        return
    fi

    local expected_batches=$(( (branch_count + batch_size - 1) / batch_size ))
    [[ "$branch_count" -eq 0 ]] && expected_batches=0

    assert_batch_count           "$label" "$json" "$expected_batches"
    assert_total_branch_count    "$label" "$json" "$branch_count"
    assert_no_empty_batches      "$label" "$json"
    assert_max_batch_size        "$label" "$json" "$batch_size"
    assert_branch_count_matches_list "$label" "$json" "$branch_count"

    if $VERBOSE; then
        echo "  Matrix JSON:"
        echo "$json" | jq .
    fi
}

# ── test cases ────────────────────────────────────────────────────────────────

echo "========================================"
echo " build-matrix test suite"
echo "========================================"

# Zero branches — should produce empty matrix
run_case "zero branches" 0

# Small non-divisible count
run_case "10 branches" 10

# Exactly one full batch
run_case "100 branches (exact)" 100

# One full batch plus a small remainder
run_case "101 branches" 101

# The exact failure scenario from Feb 2026: 300 branches, batch size 100
run_case "300 branches (exact multiple — original bug)" 300

# Large non-divisible count
run_case "684 branches" 684

# Non-default batch size
run_case "50 branches, batch size 10" 50 10
run_case "100 branches, batch size 10 (exact multiple)" 100 10

# Single branch
run_case "1 branch" 1

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "========================================"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
