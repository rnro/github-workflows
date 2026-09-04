#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift.org open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See https://swift.org/LICENSE.txt for license information
## See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
##
##===----------------------------------------------------------------------===##

# Tests that matrix/job-runner-linux.sh propagates failure.
#
# A step reporting success for a command that failed is the worst kind of bug
# this repository can ship, because every adopter believes a green check. The
# Windows equivalent of this is tests/invoke-program-tests.ps1.
#
# Runs against the native path with the toolchain install skipped, so it needs no
# Swift. Linux only: the script installs swiftly with apt and a Linux tarball.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${REPO_ROOT}/.github/workflows/scripts/matrix/job-runner-linux.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Skipping: job-runner-linux.sh needs Linux (this is $(uname -s))."
    exit 0
fi

failures=0

# run_matrix <setup_command> <command> — echoes the exit status.
run_matrix() {
    local setup="$1" command="$2"
    (
        cd "$WORKDIR" || exit 1
        SKIP_SWIFT_INSTALL=true "$RUNNER" "6.3" "$setup" "$command" "[]" "{}" "false" "" >/dev/null 2>&1
    )
    echo "$?"
}

assert_status() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "  FAIL $what: expected exit $expected, got $actual"
        failures=$((failures + 1))
    else
        echo "  ok   $what"
    fi
}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

assert_status "non-zero exit code propagates" "3" "$(run_matrix "" "exit 3")"
assert_status "zero exit code passes through" "0" "$(run_matrix "" "true")"
assert_status "a failing setup command fails the job" "4" "$(run_matrix "exit 4" "true")"
assert_status "the command runs in the setup command's directory" "0" \
    "$(run_matrix "mkdir -p sub && cd sub" "test -d ../sub")"

if [[ "$failures" -gt 0 ]]; then
    printf '\n%d failed\n' "$failures"
    exit 1
fi
printf '\nall passed\n'
