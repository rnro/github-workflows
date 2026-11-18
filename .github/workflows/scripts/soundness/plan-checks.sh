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

# Writes the matrix of soundness checks to run on standard output, as JSON for
# `strategy.matrix`. A check the caller turned off has no entry, so no job exists
# for it and the run shows no skipped job.
#
# Each entry carries:
#   check            - the identifier run-check.sh dispatches on
#   name             - the job name, which is also the status check name
#   runner           - the `runs-on` labels
#   container        - the container image, or empty to run on the runner
#   timeout_minutes  - the job's timeout
#   full_history     - whether the checkout needs every commit and tag
#
# Environment variables, each a workflow input. The enable flags are always required. A
# check's container image is required only while that check is on, and so are the macOS
# version and architecture for the macOS docs check:
#   API_BREAKAGE_CHECK_ENABLED, API_BREAKAGE_CHECK_CONTAINER_IMAGE
#   DOCS_CHECK_ENABLED, DOCS_CHECK_CONTAINER_IMAGE
#   DOCS_CHECK_MACOS_ENABLED, DOCS_CHECK_MACOS_VERSION, DOCS_CHECK_MACOS_ARCH
#   UNACCEPTABLE_LANGUAGE_CHECK_ENABLED, LICENSE_HEADER_CHECK_ENABLED
#   BROKEN_SYMLINK_CHECK_ENABLED
#   FORMAT_CHECK_ENABLED, FORMAT_CHECK_CONTAINER_IMAGE
#   SHELL_CHECK_ENABLED, SHELL_CHECK_CONTAINER_IMAGE
#   YAMLLINT_CHECK_ENABLED, PYTHON_LINT_CHECK_ENABLED
#
# The documentation checks can run across Swift versions instead of in one image or on one
# Xcode. Each of these is a JSON array of version labels, or empty:
#   DOCS_CHECK_LINUX_SWIFT_VERSIONS, DOCS_CHECK_MACOS_SWIFT_VERSIONS
# A non-empty list replaces that platform's single check with one check per version, taken from
# TOOLCHAINS, the JSON the generator emits for those versions. The macOS check without a list
# needs DOCS_CHECK_MACOS_XCODE_VERSION.

command -v jq >/dev/null || { echo "** ERROR: jq not found on PATH" >&2; exit 1; }

entries="[]"

# Succeeds while a check is on, fails while it is off, and stops on any other value.
# Arguments: check enabled
is_on() {
    case "$2" in
        true) return 0 ;;
        false) return 1 ;;
        *)
            echo "** ERROR: the enable input for '$1' is '$2', not 'true' or 'false'" >&2
            exit 1
            ;;
    esac
}

# Arguments: check name runner_json container timeout_minutes full_history xcode_app
append_entry() {
    entries=$(jq -c \
        --arg check "$1" \
        --arg name "$2" \
        --argjson runner "$3" \
        --arg container "$4" \
        --argjson timeout_minutes "$5" \
        --argjson full_history "$6" \
        --arg xcode_app "$7" \
        '. + [{
            check: $check,
            name: $name,
            runner: $runner,
            container: $container,
            timeout_minutes: $timeout_minutes,
            full_history: $full_history,
            xcode_app: $xcode_app
        }]' <<<"$entries")
}

# Arguments: enabled check name runner_json container_variable timeout_minutes [full_history] [xcode_app]
#
# `container_variable` names the variable holding the image the check runs in, or is empty
# for a check that runs on the runner. It is read only when the check is on.
add_check() {
    local enabled="$1" check="$2" name="$3" runner="$4" container_variable="$5" timeout_minutes="$6"
    local full_history="${7:-false}" xcode_app="${8:-}"

    is_on "$check" "$enabled" || return 0

    local container=""
    if [[ -n "$container_variable" ]]; then
        container="${!container_variable:-}"
        if [[ -z "$container" ]]; then
            echo "** ERROR: $container_variable is empty, but the '$check' check is on and runs in a container" >&2
            exit 1
        fi
    fi

    append_entry "$check" "$name" "$runner" "$container" "$timeout_minutes" "$full_history" "$xcode_app"
}

# Adds one entry per toolchain of a platform, named for the version label the caller wrote.
# Arguments: enabled check name_format platform timeout_minutes
#
# `name_format` is a printf format with one `%s`, which takes the label. Each entry must say where
# it runs: an image on Linux, and on macOS the Xcode app of its Swift version. Without one the
# check would run on whatever the runner has, and appear to cover a version it does not.
add_toolchain_checks() {
    local enabled="$1" check="$2" name_format="$3" platform="$4" timeout_minutes="$5"

    is_on "$check" "$enabled" || return 0
    if [[ -z "${TOOLCHAINS:-}" ]]; then
        echo "** ERROR: TOOLCHAINS is empty, but the '$check' check was asked to run across Swift versions" >&2
        exit 1
    fi

    local toolchains
    toolchains=$(jq -c --arg platform "$platform" '
        .config[]
        | select(.platform == $platform)
        | {
            label: (.name | sub("^(Linux|macOS) (Swift|Xcode) "; "")),
            runner: .runner,
            container: (.swift_build.container.image // ""),
            nightly: ((.xcode_build.swift_version // "") | startswith("nightly-")),
            xcode_app: (if .xcode_build.swift_version then "Xcode_swift_\(.xcode_build.swift_version).app" else "" end)
        }' <<<"$TOOLCHAINS")

    local count=0 toolchain label container xcode_app
    while IFS= read -r toolchain; do
        [[ -n "$toolchain" ]] || continue
        label=$(jq -r '.label' <<<"$toolchain")
        container=$(jq -r '.container' <<<"$toolchain")
        xcode_app=$(jq -r '.xcode_app' <<<"$toolchain")
        # A nightly is not an Xcode, so there is no Xcode app to name for it.
        if [[ "$(jq -r '.nightly' <<<"$toolchain")" == "true" ]]; then
            echo "** ERROR: the '$check' check cannot run on the macOS Swift version '$label': a macOS nightly needs a swiftly toolchain, not an Xcode" >&2
            exit 1
        fi
        if [[ "$platform" == "Linux" && -z "$container" ]]; then
            echo "** ERROR: the '$check' check has no container image for the Linux Swift version '$label'" >&2
            exit 1
        fi
        if [[ "$platform" == "macOS" && -z "$xcode_app" ]]; then
            echo "** ERROR: the '$check' check has no Xcode for the macOS Swift version '$label'" >&2
            exit 1
        fi
        # shellcheck disable=SC2059
        append_entry "$check" "$(printf "$name_format" "$label")" "$(jq -c '.runner' <<<"$toolchain")" \
            "$container" "$timeout_minutes" false "$xcode_app"
        count=$((count + 1))
    done <<<"$toolchains"

    if [[ "$count" -eq 0 ]]; then
        echo "** ERROR: the '$check' check was asked to run across Swift versions, but TOOLCHAINS has no $platform toolchain" >&2
        exit 1
    fi
}

hosted='["ubuntu-latest"]'

# The Linux documentation check runs once per Swift version when it is given a list, and once in
# DOCS_CHECK_CONTAINER_IMAGE otherwise, under the name "Documentation check".
add_docs_checks() {
    if [[ -n "${DOCS_CHECK_LINUX_SWIFT_VERSIONS:-}" ]]; then
        add_toolchain_checks "${DOCS_CHECK_ENABLED:?}" docs "Documentation check (Swift %s)" Linux 20
    else
        add_check "${DOCS_CHECK_ENABLED:?}" docs "Documentation check" "$hosted" DOCS_CHECK_CONTAINER_IMAGE 20
    fi
}

# The macOS documentation check runs once per Swift version when it is given a list, and once on
# the Xcode in DOCS_CHECK_MACOS_XCODE_VERSION otherwise, under the name "Documentation check (macOS)".
add_docs_macos_checks() {
    if [[ -n "${DOCS_CHECK_MACOS_SWIFT_VERSIONS:-}" ]]; then
        add_toolchain_checks "${DOCS_CHECK_MACOS_ENABLED:?}" docs-macos "Documentation check (macOS, Swift %s)" macOS 20
        return
    fi
    # The macOS inputs only matter when the check is on.
    is_on docs-macos "${DOCS_CHECK_MACOS_ENABLED:?}" || return 0
    local runner
    runner=$(jq -cn \
        --arg version "${DOCS_CHECK_MACOS_VERSION:?}" \
        --arg arch "${DOCS_CHECK_MACOS_ARCH:?}" \
        '["self-hosted", "macos", $version, $arch]')
    add_check true docs-macos "Documentation check (macOS)" "$runner" "" 20 false \
        "Xcode_${DOCS_CHECK_MACOS_XCODE_VERSION:?}.app"
}

#         enabled                                    check                 name                          runner          container variable                 timeout_minutes full_history
add_check "${API_BREAKAGE_CHECK_ENABLED:?}"          api-breakage          "API breakage check"          "$hosted"       API_BREAKAGE_CHECK_CONTAINER_IMAGE 40              true
add_docs_checks
add_docs_macos_checks
add_check "${UNACCEPTABLE_LANGUAGE_CHECK_ENABLED:?}" unacceptable-language "Unacceptable language check" "$hosted"       ""                                 1
add_check "${LICENSE_HEADER_CHECK_ENABLED:?}"        license-header        "License headers check"       "$hosted"       ""                                 1
add_check "${BROKEN_SYMLINK_CHECK_ENABLED:?}"        broken-symlink        "Broken symlinks check"       "$hosted"       ""                                 1
add_check "${FORMAT_CHECK_ENABLED:?}"                format                "Format check"                "$hosted"       FORMAT_CHECK_CONTAINER_IMAGE       20
add_check "${SHELL_CHECK_ENABLED:?}"                 shell                 "Shell check"                 "$hosted"       SHELL_CHECK_CONTAINER_IMAGE        5
add_check "${YAMLLINT_CHECK_ENABLED:?}"              yaml-lint             "YAML lint check"             "$hosted"       ""                                 5
add_check "${PYTHON_LINT_CHECK_ENABLED:?}"           python-lint           "Python lint check"           "$hosted"       ""                                 5

duplicates=$(jq -r '[.[].name] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' <<<"$entries")
if [[ -n "$duplicates" ]]; then
    echo "** ERROR: more than one check is named: $duplicates" >&2
    exit 1
fi

jq -c '{include: .}' <<<"$entries"
