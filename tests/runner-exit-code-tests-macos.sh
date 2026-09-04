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

# Tests that matrix/job-runner-macos.sh propagates failure and runs the command
# in the setup command's shell.
#
# A step reporting success for a command that failed is the worst kind of bug
# this repository can ship, because every adopter believes a green check. The
# Linux equivalent of this is tests/runner-exit-code-tests.sh.
#
# macOS only, and needs one real Xcode so `xcrun swift --version` can run. The
# script's Xcode lookup is pointed at a scratch directory holding a symlink,
# which is what XCODE_APPLICATIONS_DIRECTORY exists for.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${REPO_ROOT}/.github/workflows/scripts/matrix/job-runner-macos.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Skipping: job-runner-macos.sh needs macOS (this is $(uname -s))."
    exit 0
fi

# Any real Xcode will do; the tests never build, they only need xcrun to answer.
real_xcode=""
for candidate in /Applications/Xcode*.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
        real_xcode="$candidate"
        break
    fi
done
if [[ -z "$real_xcode" ]]; then
    echo "Skipping: no Xcode with a Contents/Developer found under /Applications."
    exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
XCODE_DIR="$WORKDIR/Applications"
mkdir -p "$XCODE_DIR"
ln -s "$real_xcode" "$XCODE_DIR/Xcode_swift_test.app"
mkdir -p "$WORKDIR/subpackage"

failures=0

# run_matrix <setup_command> <command> — echoes the exit status.
run_matrix() {
    local setup="$1" command="$2"
    (
        cd "$WORKDIR" || exit 1
        XCODE_APPLICATIONS_DIRECTORY="$XCODE_DIR" \
            "$RUNNER" "" "test" "$setup" "$command" "[]" "{}" "false" >/dev/null 2>&1
        echo "$?"
    )
}

assert_status() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "ok - $description"
    else
        echo "FAILED - $description: expected exit $expected, got $actual"
        failures=$((failures + 1))
    fi
}

# A command that fails must fail the job; anything else reports a green check for
# work that did not pass.
assert_status "a failing command fails the job" "1" \
    "$(run_matrix "" "exit 1")"

assert_status "a succeeding command passes" "0" \
    "$(run_matrix "" "true")"

# A failing setup command must stop the run, otherwise the command executes
# against whatever state the half-finished setup left behind. The exact status is
# asserted, not just non-zero, since the runner is expected to propagate it.
assert_status "a failing setup command fails the job with its own status" "3" \
    "$(run_matrix "exit 3" "true")"

# The setup command and the command share a shell, so `cd` in setup carries over.
# Without this a caller entering a subdirectory silently tests the root package.
assert_status "the command runs in the setup command's directory" "0" \
    "$(run_matrix "cd subpackage" "test \"\$(basename \"\$PWD\")\" = subpackage")"

# The converse, so the assertion above cannot pass by accident.
assert_status "without a cd the command runs in the working directory" "1" \
    "$(run_matrix "" "test \"\$(basename \"\$PWD\")\" = subpackage")"

echo
if [[ "$failures" -eq 0 ]]; then
    echo "All macOS runner tests passed."
    exit 0
fi
echo "$failures macOS runner test(s) failed."
exit 1
