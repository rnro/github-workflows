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

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
plan="${repo_root}/.github/workflows/scripts/soundness/plan-checks.sh"

failures=0

# Runs the planner with only the inputs a workflow's defaults would give it, plus the
# overrides in the arguments, and prints its JSON. Starting from an empty environment
# keeps a variable already exported in the caller's shell from satisfying a required input.
plan_json() {
    env -i PATH="${PATH}" \
        API_BREAKAGE_CHECK_ENABLED=true \
        API_BREAKAGE_CHECK_CONTAINER_IMAGE=swift:6.3-noble \
        DOCS_CHECK_ENABLED=true \
        DOCS_CHECK_CONTAINER_IMAGE=swift:6.3-noble \
        DOCS_CHECK_MACOS_ENABLED=false \
        DOCS_CHECK_MACOS_VERSION=tahoe \
        DOCS_CHECK_MACOS_ARCH=ARM64 \
        DOCS_CHECK_MACOS_XCODE_VERSION=26.0 \
        UNACCEPTABLE_LANGUAGE_CHECK_ENABLED=true \
        LICENSE_HEADER_CHECK_ENABLED=true \
        BROKEN_SYMLINK_CHECK_ENABLED=true \
        FORMAT_CHECK_ENABLED=true \
        FORMAT_CHECK_CONTAINER_IMAGE=swift:6.3-noble \
        SHELL_CHECK_ENABLED=true \
        SHELL_CHECK_CONTAINER_IMAGE=ubuntu:noble \
        YAMLLINT_CHECK_ENABLED=true \
        PYTHON_LINT_CHECK_ENABLED=true \
        "$@" \
        "${plan}"
}

planned_names() {
    plan_json "$@" | jq -r '[.include[].name] | join(",")'
}

expect() {
    local description="$1" expected="$2" actual="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        echo "PASS: ${description}"
    else
        echo "FAIL: ${description}"
        echo "  expected: ${expected}"
        echo "  actual:   ${actual}"
        failures=$((failures + 1))
    fi
}

everything_default="API breakage check,Documentation check,Unacceptable language check,License headers check,Broken symlinks check,Format check,Shell check,YAML lint check,Python lint check"

expect "defaults plan every check but macOS docs" "${everything_default}" "$(planned_names)"

expect "a disabled check has no entry" \
    "Documentation check,Unacceptable language check,License headers check,Broken symlinks check,Format check,Shell check,YAML lint check,Python lint check" \
    "$(planned_names API_BREAKAGE_CHECK_ENABLED=false)"

expect "macOS docs is planned after Linux docs" \
    "API breakage check,Documentation check,Documentation check (macOS),Unacceptable language check,License headers check,Broken symlinks check,Format check,Shell check,YAML lint check,Python lint check" \
    "$(planned_names DOCS_CHECK_MACOS_ENABLED=true)"

expect "only the docs check remains" "Documentation check" \
    "$(planned_names \
        API_BREAKAGE_CHECK_ENABLED=false UNACCEPTABLE_LANGUAGE_CHECK_ENABLED=false \
        LICENSE_HEADER_CHECK_ENABLED=false BROKEN_SYMLINK_CHECK_ENABLED=false \
        FORMAT_CHECK_ENABLED=false SHELL_CHECK_ENABLED=false \
        YAMLLINT_CHECK_ENABLED=false PYTHON_LINT_CHECK_ENABLED=false)"

macos_plan=$(plan_json DOCS_CHECK_MACOS_ENABLED=true DOCS_CHECK_MACOS_VERSION=sequoia \
    DOCS_CHECK_MACOS_ARCH=X64 DOCS_CHECK_CONTAINER_IMAGE=swift:6.4-noble)

expect "the Linux docs check runs in the image it was given" "swift:6.4-noble" \
    "$(jq -r '.include[] | select(.check == "docs") | .container' <<<"${macos_plan}")"

expect "the macOS docs check runs on the labels it was given, outside a container" \
    '["self-hosted","macos","sequoia","X64"]|' \
    "$(jq -r '.include[] | select(.check == "docs-macos") | "\(.runner | tojson)|\(.container)"' <<<"${macos_plan}")"

expect "only the API breakage check fetches full history" "api-breakage" \
    "$(plan_json | jq -r '[.include[] | select(.full_history) | .check] | join(",")')"

expect "the macOS inputs are not required while the macOS docs check is off" "${everything_default}" \
    "$(planned_names DOCS_CHECK_MACOS_VERSION= DOCS_CHECK_MACOS_ARCH=)"

expect "each check runs in its own container, with its own timeout" \
    "api-breakage=swift:6.3-noble@40,docs=swift:6.3-noble@20,unacceptable-language=@1,license-header=@1,broken-symlink=@1,format=swift:6.3-noble@20,shell=ubuntu:noble@5,yaml-lint=@5,python-lint=@5" \
    "$(plan_json | jq -r '[.include[] | "\(.check)=\(.container)@\(.timeout_minutes)"] | join(",")')"

expect "no check enabled plans no entry" '{"include":[]}' \
    "$(plan_json \
        API_BREAKAGE_CHECK_ENABLED=false DOCS_CHECK_ENABLED=false \
        UNACCEPTABLE_LANGUAGE_CHECK_ENABLED=false LICENSE_HEADER_CHECK_ENABLED=false \
        BROKEN_SYMLINK_CHECK_ENABLED=false FORMAT_CHECK_ENABLED=false SHELL_CHECK_ENABLED=false \
        YAMLLINT_CHECK_ENABLED=false PYTHON_LINT_CHECK_ENABLED=false)"

# A check that is off does not read its container image, so a caller can blank the image of a check it turned off.
expect "a disabled check does not need its container image" \
    "API breakage check,Documentation check,Unacceptable language check,License headers check,Broken symlinks check,Shell check,YAML lint check,Python lint check" \
    "$(planned_names FORMAT_CHECK_ENABLED=false FORMAT_CHECK_CONTAINER_IMAGE=)"

if error=$(planned_names FORMAT_CHECK_CONTAINER_IMAGE= 2>&1 >/dev/null) \
    || [[ "${error}" != *FORMAT_CHECK_CONTAINER_IMAGE* ]]; then
    echo "FAIL: an enabled check with no container image was not rejected by name"
    echo "  error: ${error}"
    failures=$((failures + 1))
else
    echo "PASS: an enabled check with no container image is rejected by name"
fi

# What the generator emits for the toolchains of `["current", "nightly-release", "nightly-main"]`
# on Linux and `["current"]` on macOS, cut down to the fields the planner reads.
toolchains='{"config":[
  {"name":"Linux Swift current","platform":"Linux","runner":["ubuntu-24.04"],
   "swift_build":{"container":{"image":"swift:6.4-noble"},"swift_version":"6.4"}},
  {"name":"Linux Swift nightly-release","platform":"Linux","runner":["ubuntu-24.04"],
   "swift_build":{"container":{"image":"swiftlang/swift:nightly-6.4.x-noble"},"swift_version":"nightly-release"}},
  {"name":"Linux Swift nightly-main","platform":"Linux","runner":["ubuntu-24.04"],
   "swift_build":{"container":{"image":"swiftlang/swift:nightly-main-noble"},"swift_version":"nightly-main"}},
  {"name":"macOS Swift current","platform":"macOS","runner":["self-hosted","macos","goldengate","ARM64"],
   "xcode_build":{"swift_version":"6.4"}}]}'
xcode_toolchains='{"config":[
  {"name":"macOS Xcode latest-beta","platform":"macOS","runner":["self-hosted","macos","goldengate","ARM64"],
   "xcode_build":{"xcode_version":"latest-beta"}}
]}'
nightly_toolchains='{"config":[
  {"name":"macOS Swift nightly-main","platform":"macOS","runner":["self-hosted","macos","goldengate","ARM64"],
   "xcode_build":{"swift_version":"nightly-main"}}
]}'
linux_versions='["current","nightly-release","nightly-main"]'

version_plan=$(plan_json DOCS_CHECK_LINUX_SWIFT_VERSIONS="${linux_versions}" TOOLCHAINS="${toolchains}")

expect "a list of Linux versions replaces the Linux docs check with one per version" \
    "Documentation check (Swift current),Documentation check (Swift nightly-release),Documentation check (Swift nightly-main)" \
    "$(jq -r '[.include[] | select(.check == "docs") | .name] | join(",")' <<<"${version_plan}")"

expect "each Linux docs check runs in the image of its version" \
    "swift:6.4-noble,swiftlang/swift:nightly-6.4.x-noble,swiftlang/swift:nightly-main-noble" \
    "$(jq -r '[.include[] | select(.check == "docs") | .container] | join(",")' <<<"${version_plan}")"

expect "the checks that are not version specific are planned as before" \
    "API breakage check,Unacceptable language check,License headers check,Broken symlinks check,Format check,Shell check,YAML lint check,Python lint check" \
    "$(jq -r '[.include[] | select(.check != "docs") | .name] | join(",")' <<<"${version_plan}")"

macos_version_plan=$(plan_json DOCS_CHECK_MACOS_ENABLED=true DOCS_CHECK_MACOS_SWIFT_VERSIONS='["current"]' \
    TOOLCHAINS="${toolchains}")

expect "a list of macOS versions replaces the macOS docs check with one per version" \
    "Documentation check (macOS, Swift current)|Xcode_swift_6.4.app|[\"self-hosted\",\"macos\",\"goldengate\",\"ARM64\"]" \
    "$(jq -r '.include[] | select(.check == "docs-macos") | "\(.name)|\(.xcode_app)|\(.runner | tojson)"' <<<"${macos_version_plan}")"

expect "the macOS docs check without a list keeps its name and takes its Xcode from the input" \
    "Documentation check (macOS)|Xcode_26.0.app" \
    "$(plan_json DOCS_CHECK_MACOS_ENABLED=true \
        | jq -r '.include[] | select(.check == "docs-macos") | "\(.name)|\(.xcode_app)"')"

# Fails when the planner succeeds or its error does not mention the expected text. A planner that
# crashes for another reason is told apart by the text.
expect_rejected() {
    local description="$1" mentioned="$2"
    shift 2
    local error
    if error=$(plan_json "$@" 2>&1 >/dev/null) || [[ "${error}" != *"${mentioned}"* ]]; then
        echo "FAIL: ${description}"
        echo "  error: ${error}"
        failures=$((failures + 1))
    else
        echo "PASS: ${description}"
    fi
}

expect_rejected "a macOS nightly is rejected by name" "nightly-main" \
    DOCS_CHECK_MACOS_ENABLED=true DOCS_CHECK_MACOS_SWIFT_VERSIONS='["nightly-main"]' TOOLCHAINS="${nightly_toolchains}"

expect_rejected "a macOS toolchain with no Swift version is rejected by name" "latest-beta" \
    DOCS_CHECK_MACOS_ENABLED=true DOCS_CHECK_MACOS_SWIFT_VERSIONS='["latest-beta"]' TOOLCHAINS="${xcode_toolchains}"

expect_rejected "a Linux toolchain with no container image is rejected by name" "Swift version 'current'" \
    DOCS_CHECK_LINUX_SWIFT_VERSIONS='["current"]' \
    TOOLCHAINS="$(jq -c 'del(.config[] | select(.platform == "Linux") | .swift_build.container)' <<<"${toolchains}")"

expect_rejected "a list that leaves no toolchain for the platform is rejected by name" "no Linux toolchain" \
    DOCS_CHECK_LINUX_SWIFT_VERSIONS='[]' TOOLCHAINS='{"config":[]}'

expect_rejected "two checks with one name are rejected by name" "Documentation check (Swift current)" \
    DOCS_CHECK_LINUX_SWIFT_VERSIONS='["current","current"]' \
    TOOLCHAINS="$(jq -c '.config += [.config[0]]' <<<"${toolchains}")"

expect "a disabled docs check plans no docs entry, and the rest as before" \
    "API breakage check,Unacceptable language check,License headers check,Broken symlinks check,Format check,Shell check,YAML lint check,Python lint check" \
    "$(planned_names DOCS_CHECK_ENABLED=false DOCS_CHECK_LINUX_SWIFT_VERSIONS="${linux_versions}" TOOLCHAINS="${toolchains}")"

if error=$(plan_json DOCS_CHECK_LINUX_SWIFT_VERSIONS="${linux_versions}" 2>&1 >/dev/null) \
    || [[ "${error}" != *TOOLCHAINS* ]]; then
    echo "FAIL: a list of versions with no toolchains was not rejected by name"
    echo "  error: ${error}"
    failures=$((failures + 1))
else
    echo "PASS: a list of versions with no toolchains is rejected by name"
fi

if planned_names FORMAT_CHECK_ENABLED=yes >/dev/null 2>&1; then
    echo "FAIL: a value that is not true or false was accepted"
    failures=$((failures + 1))
else
    echo "PASS: a value that is not true or false is rejected"
fi

if [[ "${failures}" -ne 0 ]]; then
    echo "${failures} failure(s)"
    exit 1
fi
