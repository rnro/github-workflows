#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift.org open source project
##
## Copyright (c) 2025 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See https://swift.org/LICENSE.txt for license information
## See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
##
##===----------------------------------------------------------------------===##

set -euo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

# jq and yq are called by name, not through a variable: shellcheck recognizes them
# literally and only then knows their single-quoted filters are not shell expansions.
command -v jq >/dev/null || fatal "jq not found on PATH"
command -v yq >/dev/null || fatal "yq not found on PATH"

# Converts a YAML or JSON value to JSON. JSON is accepted as-is.
to_json() { echo "$1" | yq -o=json; }

# Converts a value to JSON, dropping yq's own diagnostic. yq reads the value from
# stdin, so its message names `-` and the line within it — neither the input the
# value came from nor the value itself. The callers below report both.
#
# $1 (string): the value
yaml_to_json() { echo "$1" | yq -o=json 2>/dev/null; }

# Converts a list input to a JSON array, failing when the value is not a list.
#
# Every list input arrives as a string. A value that is not an array reaches
# `jq -r '.[]'` in the process substitution feeding a `while` loop, where the
# failure is invisible: it is not the shell's exit status, so `set -e` never sees
# it, the loop body runs zero times, and the platform is absent from a run that
# still reports success.
#
# $1 (string): the input's name, for the error message
# $2 (string): the value
to_json_array() {
    local name="$1" value="$2" json
    json=$(yaml_to_json "$value") || fatal "$name is not valid JSON or YAML: $value"
    if ! echo "$json" | jq -e 'type == "array"' > /dev/null; then
        fatal "$name must be a list, such as [\"a\", \"b\"], but got: $value"
    fi
    echo "$json"
}

# Converts a per-version overrides input to JSON, failing when it is not a map of
# version to override.
#
# The override for a version is read out of this map by indexing it, so a value of
# any other shape is a jq error rather than an absent override — and an error there
# is indistinguishable from a version with nothing to add. The arguments the caller
# asked for are then missing from a job that still reports success, which is how a
# repository loses warnings-as-errors.
#
# $1 (string): the input's name, for the error message
# $2 (string): the value
version_overrides_to_json() {
    local name="$1" value="$2" json invalid
    json=$(yaml_to_json "$value") || fatal "$name is not valid JSON or YAML: $value"
    # A value that carried nothing — blank, or an explicit null — is no overrides
    # rather than a malformed map.
    if [[ "$json" == "null" ]]; then
        echo "{}"
        return
    fi
    if ! echo "$json" | jq -e 'type == "object"' > /dev/null; then
        fatal "$name must be a map of version to override, such as {\"6.3\": \"-Xswiftc -warnings-as-errors\"}, but got: $value"
    fi

    # An override is the arguments as a string, or a map of command and arguments.
    invalid=$(echo "$json" | jq -r '
        to_entries
        | map(select((.value | type) as $t | $t != "string" and $t != "object"))
        | map("\(.key): \(.value | tojson)")
        | join(", ")')
    if [[ -n "$invalid" ]]; then
        fatal "$name takes the arguments as a string, or a map with command and arguments, but got: $invalid"
    fi

    # A misspelled key inside the map, or a value that is not a string, carries
    # nothing while looking as though it does.
    invalid=$(echo "$json" | jq -r '
        to_entries
        | map(select((.value | type) == "object"))
        | map(select(((.value | keys) - ["arguments", "command"] | length) > 0
              or any(.value[]; type != "string")))
        | map("\(.key): \(.value | tojson)")
        | join(", ")')
    if [[ -n "$invalid" ]]; then
        fatal "$name takes command and arguments, each a string, but got: $invalid"
    fi

    echo "$json"
}

# Whether an input's value is a collection — a list or a map — rather than a
# scalar. Fails the run when the value parses as neither, which is a value that is
# not YAML or JSON at all.
#
# This is how an input that takes either shape tells them apart. The parse
# classifies the value and nothing more: a scalar is used exactly as it was
# written, because YAML reads `24.10` as the number 24.1 and drops everything
# after a ` #`, so a round-tripped scalar is not the value the caller wrote.
#
# $1 (string): the input's name, for the error message
# $2 (string): the value
input_is_collection() {
    local name="$1" value="$2" json
    json=$(yaml_to_json "$value") || fatal "$name is not valid JSON or YAML: $value"
    echo "$json" | jq -e 'type == "array" or type == "object"' > /dev/null
}

# A one-element JSON array holding the value byte for byte.
#
# $1 (string): the value
scalar_to_json_array() {
    jq -n -c --arg value "$1" '[$value]'
}

# The shape a label in a `*_command` map has to take. It leads the job name, so it
# is a word; that is also what keeps a shell command YAML read as a map from being
# mistaken for one.
COMMAND_LABEL_PATTERN='^[A-Za-z0-9][A-Za-z0-9_.-]*$'

# Resolves a `*_command` input to the commands it names: one entry per label when
# the value is a map of them, and a single unlabeled entry otherwise.
#
#   linux_command: swift test
#
#   linux_command: |
#     test: swift test
#     release:
#       command: swift build -c release
#       versions: ["6.3"]
#
# The parse only classifies. Anything but a map of labels is the command itself,
# taken byte for byte — including a value that is not YAML at all, such as
# `[ -f x ] && swift build` — because YAML reads `24.10` as the number 24.1 and
# drops everything after a ` #`.
#
# A shell command can parse as a map: `swift test --filter Foo: Bar` yields one
# keyed on everything before the colon. Requiring every key to be a label leaves
# only `<word>: <rest>` ambiguous, and that names a program whose name ends in a
# colon, so it is not a command that would have run.
#
# $1 (string): the input's name, for the error message
# $2 (string): the value
commands_to_json() {
    local name="$1" value="$2" json invalid
    json=$(yaml_to_json "$value") || json="null"

    if echo "$json" | jq -e 'type == "array"' > /dev/null; then
        fatal "$name takes a command, or a map of label to command such as {test: swift test}, but got a list: $value"
    fi
    if ! echo "$json" | jq -e --arg pattern "$COMMAND_LABEL_PATTERN" \
        'type == "object" and (keys_unsorted | length) > 0 and all(keys_unsorted[]; test($pattern))' \
        > /dev/null
    then
        jq -n -c --arg command "$value" '[{label: "", command: $command}]'
        return
    fi

    # yq keeps a repeated key while jq takes the last of them, so a label written
    # twice would run one command of the two the caller named — and under the bare
    # name, since one command earns no suffix.
    if [[ "$(echo "$value" | yq 'keys | length')" != "$(echo "$json" | jq 'length')" ]]; then
        fatal "$name names a label more than once: $value"
    fi

    # A label carrying anything else — a number, a list, a misspelled key, a blank
    # command, an empty version list — would leave the job running the kind's
    # default command under a name that says otherwise, or produce no job for that
    # label at all.
    invalid=$(echo "$json" | jq -r '
        to_entries
        | map(select(
            (.value | type) as $type
            | if $type == "string" then ((.value | test("\\S")) | not)
              elif $type == "object" then
                  (((.value | keys) - ["command", "versions"]) | length) > 0
                  or ((.value.command | type) != "string")
                  or ((.value.command | test("\\S")) | not)
                  or ((.value.versions != null)
                      and (((.value.versions | type) != "array")
                           or ((.value.versions | length) == 0)
                           or any(.value.versions[]; type != "string")))
              else true
              end))
        | map("\(.key): \(.value | tojson)")
        | join(", ")')
    if [[ -n "$invalid" ]]; then
        fatal "$name takes each label's command as a non-blank string, or a map of command and a non-empty versions list, but got: $invalid"
    fi

    echo "$json" | jq -c '
        to_entries
        | map(if (.value | type) == "string"
              then {label: .key, command: .value}
              else {label: .key, command: .value.command}
                   + (if .value.versions == null then {} else {versions: .value.versions} end)
              end)'
}

# The versions one command entry runs on: the ones its label selected, in the
# kind's own order, or the kind's whole list when the label selected none.
#
# $1 (string): the command entry, as JSON
# $2 (string): the kind's version list, a JSON array
command_entry_versions() {
    jq -c -n --argjson entry "$1" --argjson versions "$2" '
        if $entry.versions == null then $versions
        else [$versions[] | select(. as $v | $entry.versions | index($v))] end'
}

# Fails when a label selects a version its kind does not run.
#
# The label selects from the kind's version list, so a version the list does not
# hold contributes no entries: the command the caller asked for is missing from a
# run that still reports success.
#
# $1 (string): "true" when the kind is enabled. A kind that is off reads none of
#              this, so a label naming nothing loses nothing, and failing there
#              would take down the kinds that are on.
# $2 (string): the command input's name, for the error message
# $3 (string): the commands, as JSON
# $4 (string): the versions the kind runs, a JSON array
validate_command_versions() {
    local enabled="$1" name="$2" commands_json="$3" kind_versions="$4" unmatched
    [[ "$enabled" == "true" ]] || return 0
    unmatched=$(jq -r -n --argjson commands "$commands_json" --argjson versions "$kind_versions" '
        [$commands[]
         | select(.versions != null)
         | . as $entry
         | (.versions - $versions)[]
         | "\($entry.label): \(.)"]
        | join(", ")')
    if [[ -n "$unmatched" ]]; then
        fatal "$name selects versions the matrix does not hold: $unmatched. Valid versions: $(echo "$kind_versions" | jq -r 'join(" ")')"
    fi
}

# Fails when a per-version `command:` override has no single command to replace.
#
# The override replaces the command for a version. A labeled map has one command
# per label, so honoring it would give every label the same command and leave
# jobs that differ only in name.
#
# $1 (string): the command input's name, for the error message
# $2 (string): the commands, as JSON
# $3 (string): the overrides input's name, for the error message
# $4 (string): the overrides, as JSON
# $5 (string): the versions the kind runs, a JSON array
validate_one_command_to_override() {
    local commands_name="$1" commands_json="$2" overrides_name="$3" overrides_json="$4" \
        kind_versions="$5" replaced
    [[ "$(echo "$commands_json" | jq 'length')" -gt 1 ]] || return 0
    replaced=$(overridden_versions "$overrides_json" "$kind_versions")
    if [[ -n "$replaced" ]]; then
        fatal "$overrides_name replaces the command for $replaced, but $commands_name has more than one command configured, so there is no single command to replace. Give that label its own versions instead."
    fi
}

# The versions a per-version overrides object replaces the command for, of those a
# job kind runs. A key naming a version the kind's own list does not hold reaches
# none of its entries, so it is not that kind's business.
#
# $1 (string): the overrides, as JSON
# $2 (string): the versions the kind runs, a JSON array
overridden_versions() {
    jq -r -n --argjson overrides "$1" --argjson versions "$2" '
        [$overrides | to_entries[]
         | select((.value | type) == "object" and (.value.command // "") != "")
         | select(.key as $key | $versions | index($key))
         | .key]
        | join(", ")'
}

# Maps a Linux host architecture to its GitHub-hosted runner label.
#
# $1 (string): "x86_64" or "aarch64"
linux_runner_for_arch() {
    if [[ "$1" == "aarch64" ]]; then
        echo "ubuntu-24.04-arm"
    else
        echo "ubuntu-24.04"
    fi
}


# ---------------------------------------------------------------------------
# Platform enable flags
# ---------------------------------------------------------------------------
enable_linux="${ENABLE_LINUX:-true}"
enable_macos="${ENABLE_MACOS:-false}"
enable_windows="${ENABLE_WINDOWS:-true}"
enable_linux_static_sdk="${ENABLE_LINUX_STATIC_SDK_BUILD:-false}"
enable_wasm_sdk="${ENABLE_WASM_SDK_BUILD:-false}"
enable_embedded_wasm_sdk="${ENABLE_EMBEDDED_WASM_SDK_BUILD:-false}"
enable_android_sdk="${ENABLE_ANDROID_SDK_BUILD:-false}"
enable_android_emulator_tests="${ENABLE_ANDROID_EMULATOR_TESTS:-false}"
enable_cxx_interop="${ENABLE_CXX_INTEROP:-false}"
enable_freebsd="${ENABLE_FREEBSD:-false}"
freebsd_swift_versions=$(to_json_array "freebsd_swift_versions" "${FREEBSD_SWIFT_VERSIONS:-"[\"nightly-main\"]"}")
freebsd_os_versions=$(to_json_array "freebsd_os_versions" "${FREEBSD_OS_VERSIONS:-"[\"14.3\"]"}")
freebsd_commands=$(commands_to_json "freebsd_command" "${FREEBSD_COMMAND:-swift test}")
freebsd_setup_command="${FREEBSD_SETUP_COMMAND:-}"
freebsd_env_vars="${FREEBSD_ENV_VARS:-}"

# ---------------------------------------------------------------------------
# Version lists (JSON arrays)
# ---------------------------------------------------------------------------

# nightly-release is an alias for the nightly of the next Swift release branch.
#
# The token below is the branch spelling upstream publishes under: 6.0 through 
# 6.3 were "6.<n>", 6.4 is "6.4.x".
nightly_release_token="${NIGHTLY_RELEASE_TOKEN:-6.4.x}"

default_linux_versions='["6.1", "6.2", "6.3", "nightly-release", "nightly-main"]'
default_macos_swift_versions='["6.1", "6.2", "6.3"]'
default_windows_versions='["6.1", "6.2", "6.3", "nightly-release", "nightly-main"]'
default_sdk_versions='["6.3", "nightly-release", "nightly-main"]'
default_android_versions='["6.3", "nightly-release", "nightly-main"]'
default_android_sdk_triples='["aarch64-unknown-linux-android28", "x86_64-unknown-linux-android28"]'
# Both NDK releases the Android Swift SDK is used with, so a package that builds
# against one and not the other is caught.
default_android_ndk_versions='["r27d", "r28c"]'

linux_swift_versions=$(to_json_array "linux_swift_versions" "${LINUX_SWIFT_VERSIONS:-$default_linux_versions}")
DEFAULT_LINUX_OS="noble"
# A distribution, which becomes the container image tag's suffix, or a list of them.
linux_os="${LINUX_OS:-$DEFAULT_LINUX_OS}"
linux_host_archs=$(to_json_array "linux_host_archs" "${LINUX_HOST_ARCHS:-"[\"x86_64\"]"}")

# ---------------------------------------------------------------------------
# Docker config
# ---------------------------------------------------------------------------

linux_use_docker="${LINUX_USE_DOCKER:-false}"
# Container knobs passed straight through to `docker run`. A Dockerfile is built
# on the runner, from the image as its base, and the result is used instead.
linux_dockerfile="${LINUX_DOCKERFILE:-}"
linux_docker_capabilities=$(to_json_array "linux_docker_capabilities" "${LINUX_DOCKER_CAPABILITIES:-"[]"}")
linux_docker_security_options=$(to_json_array "linux_docker_security_options" "${LINUX_DOCKER_SECURITY_OPTIONS:-"[]"}")
# A Dockerfile is built from a base image, so it implies container mode.
if [[ -n "$linux_dockerfile" ]]; then
    linux_use_docker="true"
fi

# ---------------------------------------------------------------------------
# OS config
# ---------------------------------------------------------------------------

# LINUX_OS takes a distribution or a list of them.
if input_is_collection "linux_os" "$linux_os"; then
    linux_os_list=$(to_json_array "linux_os" "$linux_os")
    # A list names container images, so any list — even of one — runs in a
    # container. Left native, the job would run on the runner's own distribution
    # and pass, having tested nothing about the one asked for.
    if [[ "$linux_use_docker" != "true" ]]; then
        log "linux_os names a list, so Linux runs in a container"
    fi
    linux_use_docker="true"
else
    linux_os_list=$(scalar_to_json_array "$linux_os")
    if [[ "$linux_os" != "$DEFAULT_LINUX_OS" && "$linux_use_docker" != "true" ]]; then
        log "linux_os is $linux_os rather than $DEFAULT_LINUX_OS, so Linux runs in a container"
        linux_use_docker="true"
    fi
fi
linux_os_count=$(echo "$linux_os_list" | jq 'length')
arch_count=$(echo "$linux_host_archs" | jq 'length')
# The architecture the SDK builds, the release build and the Cxx interop check run
# on: they do not fan out over architecture, so they follow the first one configured
# rather than defaulting to a different one from the tests.
primary_linux_runner=$(linux_runner_for_arch "$(echo "$linux_host_archs" | jq -r '.[0] // "x86_64"')")

# ---------------------------------------------------------------------------
# macOS config
# ---------------------------------------------------------------------------

macos_xcode_versions="${MACOS_XCODE_VERSIONS:-}"
macos_swift_versions="${MACOS_SWIFT_VERSIONS:-}"
if [[ -z "$macos_xcode_versions" && -z "$macos_swift_versions" ]]; then
    macos_swift_versions="$default_macos_swift_versions"
fi
if [[ -n "$macos_xcode_versions" ]]; then
    macos_xcode_versions=$(to_json_array "macos_xcode_versions" "$macos_xcode_versions")
fi
if [[ -n "$macos_swift_versions" ]]; then
    macos_swift_versions=$(to_json_array "macos_swift_versions" "$macos_swift_versions")
fi
DEFAULT_MACOS_OS="tahoe"
# A runner label, or a list of them.
macos_os="${MACOS_OS:-$DEFAULT_MACOS_OS}"
if input_is_collection "macos_os" "$macos_os"; then
    macos_os_list=$(to_json_array "macos_os" "$macos_os")
else
    macos_os_list=$(scalar_to_json_array "$macos_os")
fi
macos_os_count=$(echo "$macos_os_list" | jq 'length')
macos_arch="${MACOS_ARCH:-ARM64}"
macos_runner_pool="${MACOS_RUNNER_POOL:-general}"
# Owner whose self-hosted macOS pools these entries require. Empty means no check.
macos_repository_owner="${MACOS_REPOSITORY_OWNER:-}"
github_repository_owner="${GITHUB_REPOSITORY_OWNER:-}"
xcode_debug_output="${XCODE_DEBUG_OUTPUT:-false}"
# macOS entries driven by a swiftly-managed toolchain rather than the Xcode that
# ships one. Each entry pairs an Xcode with a swiftly selector.
enable_macos_swiftly="${ENABLE_MACOS_SWIFTLY:-false}"
default_macos_swiftly_toolchains='[{"xcode_version": "swift_6.3", "swiftly_toolchain": "main-snapshot"}]'
macos_swiftly_toolchains=$(to_json_array "macos_swiftly_toolchains" "${MACOS_SWIFTLY_TOOLCHAINS:-$default_macos_swiftly_toolchains}")
macos_swiftly_commands=$(commands_to_json "macos_swiftly_command" "${MACOS_SWIFTLY_COMMAND:-swiftly run swift test}")
# These entries fan out over macos_swiftly_toolchains rather than a version list,
# so a label has nothing to select versions from.
if echo "$macos_swiftly_commands" | jq -e 'any(.[]; .versions != null)' > /dev/null; then
    fatal "macos_swiftly_command takes no versions; its toolchains come from macos_swiftly_toolchains."
fi

# ---------------------------------------------------------------------------
# Windows config
# ---------------------------------------------------------------------------

windows_swift_versions=$(to_json_array "windows_swift_versions" "${WINDOWS_SWIFT_VERSIONS:-$default_windows_versions}")
# A runner label, or a list of them.
windows_os="${WINDOWS_OS:-windows-2022}"
if input_is_collection "windows_os" "$windows_os"; then
    windows_os_list=$(to_json_array "windows_os" "$windows_os")
else
    windows_os_list=$(scalar_to_json_array "$windows_os")
fi

# ---------------------------------------------------------------------------
# SDK configs
# ---------------------------------------------------------------------------

linux_static_sdk_versions=$(to_json_array "linux_static_sdk_versions" "${LINUX_STATIC_SDK_VERSIONS:-$default_sdk_versions}")
wasm_sdk_versions=$(to_json_array "wasm_sdk_versions" "${WASM_SDK_VERSIONS:-$default_sdk_versions}")
embedded_wasm_sdk_versions=$(to_json_array "embedded_wasm_sdk_versions" "${EMBEDDED_WASM_SDK_VERSIONS:-$default_sdk_versions}")
android_sdk_versions=$(to_json_array "android_sdk_versions" "${ANDROID_SDK_VERSIONS:-$default_android_versions}")
android_ndk_versions=$(to_json_array "android_ndk_versions" "${ANDROID_NDK_VERSIONS:-$default_android_ndk_versions}")
android_sdk_triples=$(to_json_array "android_sdk_triples" "${ANDROID_SDK_TRIPLES:-$default_android_sdk_triples}")

# ---------------------------------------------------------------------------
# Commands & flags
# ---------------------------------------------------------------------------
# Each of these takes one command, or a map of label to command: the command is a
# matrix axis like the version and the OS, so a caller wanting a release build
# alongside the tests asks for a second command rather than a second job kind.
linux_commands=$(commands_to_json "linux_command" "${LINUX_COMMAND:-swift test}")
linux_setup_command="${LINUX_SETUP_COMMAND:-}"
macos_commands=$(commands_to_json "macos_command" "${MACOS_COMMAND:-xcrun swift test}")
macos_setup_command="${MACOS_SETUP_COMMAND:-}"
windows_commands=$(commands_to_json "windows_command" "${WINDOWS_COMMAND:-swift test}")
windows_setup_command="${WINDOWS_SETUP_COMMAND:-}"
linux_static_sdk_commands=$(commands_to_json "linux_static_sdk_command" "${LINUX_STATIC_SDK_COMMAND:-swift build}")
linux_static_sdk_setup_command="${LINUX_STATIC_SDK_SETUP_COMMAND:-}"
wasm_sdk_commands=$(commands_to_json "wasm_sdk_command" "${WASM_SDK_COMMAND:-swift build}")
wasm_sdk_setup_command="${WASM_SDK_SETUP_COMMAND:-}"
embedded_wasm_sdk_commands=$(commands_to_json "embedded_wasm_sdk_command" "${EMBEDDED_WASM_SDK_COMMAND:-swift build}")
embedded_wasm_sdk_setup_command="${EMBEDDED_WASM_SDK_SETUP_COMMAND:-}"
android_sdk_commands=$(commands_to_json "android_sdk_command" "${ANDROID_SDK_COMMAND:-swift build}")
android_sdk_setup_command="${ANDROID_SDK_SETUP_COMMAND:-}"
# The Cxx interop check runs one fixed command: it is the check rather than a place
# to run one, so it takes no command as input. The runner expands SCRIPTS_ROOT, so
# that reference stays literal here.
cxx_interop_commands=$(jq -n -c --arg command "\${SCRIPTS_ROOT}/check-cxx-interop.sh" '[{label: "", command: $command}]')
swift_flags="${SWIFT_FLAGS:-}"
swift_nightly_flags="${SWIFT_NIGHTLY_FLAGS:-}"

# Per-version overrides (JSON object). A string adds arguments; an object can
# replace the command.
linux_version_overrides=$(version_overrides_to_json "linux_version_overrides" "${LINUX_VERSION_OVERRIDES:-"{}"}")
windows_version_overrides=$(version_overrides_to_json "windows_version_overrides" "${WINDOWS_VERSION_OVERRIDES:-"{}"}")
macos_version_overrides=$(version_overrides_to_json "macos_version_overrides" "${MACOS_VERSION_OVERRIDES:-"{}"}")

# ---------------------------------------------------------------------------
# Environment variables (JSON objects)
# ---------------------------------------------------------------------------
linux_env_vars=$(to_json "${LINUX_ENV_VARS:-"{}"}")
macos_env_vars=$(to_json "${MACOS_ENV_VARS:-"{}"}")
windows_env_vars=$(to_json "${WINDOWS_ENV_VARS:-"{}"}")

# ---------------------------------------------------------------------------
# Xcodebuild platform targets (macOS jobs only)
# ---------------------------------------------------------------------------
# The scheme each target uses unless it names one of its own.
xcode_scheme="${XCODE_SCHEME:-}"
# The platforms to build and test through xcodebuild: a map of platform to that
# target's settings, or a list of platforms taking every setting's default.
xcode_targets_input="${XCODE_TARGETS:-}"

# An Apple-platform target rides on a macOS entry, so asking for one without
# enabling macOS produces no jobs at all.
if [[ -n "$xcode_targets_input" && "$enable_macos" != "true" ]]; then
    fatal "xcode_targets is set but enable_macos is false; xcodebuild targets run on macOS entries."
fi

# ---------------------------------------------------------------------------
# Docker/container mode
# ---------------------------------------------------------------------------
windows_use_docker="${WINDOWS_USE_DOCKER:-false}"

# ---------------------------------------------------------------------------
# Output mode
# ---------------------------------------------------------------------------
# "jobs" (the default) emits complete matrix entries: a toolchain plus the
# command to run on it. "toolchains" emits only the toolchain axis — the
# platforms, runners, versions and images that are supported — leaving the
# command out for a caller to supply via execute_matrix.yml's inputs. Job kinds
# that exist only to run a particular command (SDK builds, release builds, Cxx
# interop, the Android emulator, FreeBSD) have no meaning without one, so
# toolchains mode does not emit them.
matrix_mode="${MATRIX_MODE:-jobs}"
case "$matrix_mode" in
    jobs) ;;
    toolchains)
        enable_linux_static_sdk="false"
        enable_wasm_sdk="false"
        enable_embedded_wasm_sdk="false"
        enable_android_sdk="false"
        enable_android_emulator_tests="false"
        enable_cxx_interop="false"
        enable_freebsd="false"
        ;;
    *)
        fatal "MATRIX_MODE must be 'jobs' or 'toolchains', got '$matrix_mode'"
        ;;
esac

# Require the SDK build for the emulator tests, which run what it produced.
# Checked after the mode handling, which clears both enables for toolchains.
if [[ "$enable_android_emulator_tests" == "true" && "$enable_android_sdk" != "true" ]]; then
    fatal "enable_android_emulator_tests needs enable_android_sdk_build; the emulator runs what that build produces."
fi

# The matrix is assembled as JSON; YAML is a conversion on the way out for the
# workflows that pass it around as a string. A decoder can ask for JSON instead.
matrix_format="${MATRIX_FORMAT:-yaml}"
case "$matrix_format" in
    yaml | json) ;;
    *)
        fatal "MATRIX_FORMAT must be 'yaml' or 'json', got '$matrix_format'"
        ;;
esac

# ---------------------------------------------------------------------------
# Minimum version detection
# ---------------------------------------------------------------------------
min_swift_version_input="${MINIMUM_SWIFT_VERSION:-}"
find_subdirectory_manifests="${ENABLE_SUBDIRECTORY_MANIFEST_SEARCH:-false}"

# ===========================================================================
# Utility functions
# ===========================================================================

version_gte() {
    local v1="$1" v2="$2"
    # Both have to be numeric: a label like "latest-beta" would otherwise reach
    # the arithmetic below and abort with a bash unbound-variable error naming
    # neither the input nor the value.
    local numeric='^[0-9]+(\.[0-9]+){0,2}$'
    if ! [[ "$v1" =~ $numeric ]]; then
        fatal "Cannot compare '$v1' as a version. A Swift version list takes numbers like 6.3, or a nightly- label; '$v1' is neither."
    fi
    if ! [[ "$v2" =~ $numeric ]]; then
        fatal "Cannot compare '$v2' as a version: minimum_swift_version must be a number like 6.3, 'none', or empty."
    fi
    IFS='.' read -r v1_major v1_minor v1_patch <<< "$v1"
    v1_minor=${v1_minor:-0}; v1_patch=${v1_patch:-0}
    IFS='.' read -r v2_major v2_minor v2_patch <<< "$v2"
    v2_minor=${v2_minor:-0}; v2_patch=${v2_patch:-0}
    if (( v1_major > v2_major )); then return 0; fi
    if (( v1_major < v2_major )); then return 1; fi
    if (( v1_minor > v2_minor )); then return 0; fi
    if (( v1_minor < v2_minor )); then return 1; fi
    if (( v1_patch >= v2_patch )); then return 0; fi
    return 1
}

get_tools_version() {
    local manifest="$1"
    [[ -f "$manifest" ]] || { echo ""; return; }
    head -n 1 "$manifest" | sed -n 's#^// *swift-tools-version: *\([0-9.]*\).*#\1#p'
}

find_minimum_swift_version() {
    local min_version=""

    local default_version
    default_version=$(get_tools_version "Package.swift")
    if [[ -n "$default_version" ]]; then
        min_version="$default_version"
        log "Found Package.swift with tools-version: $default_version"
    fi

    if [[ "$find_subdirectory_manifests" == "true" ]]; then
        while read -r manifest; do
            [[ -f "$manifest" ]] || continue
            local version
            version=$(get_tools_version "$manifest")
            if [[ -n "$version" ]]; then
                log "Found $manifest with tools-version: $version"
                if [[ -z "$min_version" ]] || version_gte "$min_version" "$version"; then
                    min_version="$version"
                fi
            fi
        done < <(ls -1 ./*/Package.swift 2>/dev/null || true)
    fi

    for manifest in Package@swift-*.swift; do
        [[ -f "$manifest" ]] || continue
        local version
        version=$(get_tools_version "$manifest")
        [[ -n "$version" ]] || continue
        log "Found $manifest with tools-version: $version"
        if [[ -z "$min_version" ]] || version_gte "$min_version" "$version"; then
            min_version="$version"
        fi
    done

    if [[ "$find_subdirectory_manifests" == "true" ]]; then
        while read -r manifest; do
            [[ -f "$manifest" ]] || continue
            local version
            version=$(get_tools_version "$manifest")
            if [[ -n "$version" ]]; then
                log "Found $manifest with tools-version: $version"
                if [[ -z "$min_version" ]] || version_gte "$min_version" "$version"; then
                    min_version="$version"
                fi
            fi
        done < <(ls -1 ./*/Package@swift-*.swift 2>/dev/null || true)
    fi

    echo "$min_version"
}

should_include_version() {
    local version="$1"
    [[ "$min_swift_version" == "none" ]] && return 0
    [[ -z "$min_swift_version" ]] && return 0
    [[ "$version" =~ ^nightly- ]] && return 0
    version_gte "$version" "$min_swift_version"
}

# The versions of a list that survive the minimum-version filter, in the list's
# order.
#
# $1 (string): the versions, a JSON array
versions_above_minimum() {
    local versions_json="$1" version
    local kept=()
    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        should_include_version "$version" || continue
        kept+=("$version")
    done < <(echo "$versions_json" | jq -r '.[]')
    if [[ "${#kept[@]}" -eq 0 ]]; then
        echo "[]"
        return
    fi
    jq -n -c '$ARGS.positional' --args "${kept[@]}"
}

# What a caller does about it. The filter is not an input of its own, so a message
# that names only what was dropped leaves them looking for a knob that isn't there.
MINIMUM_VERSION_REMEDY="The minimum comes from the manifest's swift-tools-version unless minimum_swift_version overrides it, so raise the versions, or lower minimum_swift_version — 'none' turns the filter off."

# Fails when the minimum-version filter leaves an enabled job kind, or one of its
# labelled commands, nothing to run.
#
# Dropping some versions is what the filter is for: a sweep reaching further back
# than the package supports is meant to lose the ones it cannot build on. Dropping
# all of them is not. The kind the caller asked for then contributes no entries and
# the run still reports success, and neither existing check sees it: the
# whole-matrix guard fires only when no other kind produced anything, and
# validate_command_versions compares a label against the kind's list without ever
# consulting the filter.
#
# $1 (string): "true" when the kind is enabled. A kind that is off runs nothing, so
#              a list the filter empties costs it nothing.
# $2 (string): the enable input's name, for the error message
# $3 (string): the versions input's name, for the error message
# $4 (string): the versions the kind runs, a JSON array
# $5 (string): the command input's name, for the error message. Empty says the
#              kind's command is the check itself, which takes no versions.
# $6 (string): the commands, as JSON, or empty
# $7 (string): versions a label may also select that the filter never sees, a JSON
#              array, or empty. Only macOS has any: its Xcode list names Xcodes
#              rather than Swift versions, so a label naming one is not an emptied
#              label.
require_runnable_versions() {
    local enabled="$1" enable_name="$2" versions_name="$3" versions="$4" \
        commands_name="$5" commands="$6" unfiltered="${7:-}"

    [[ "$enabled" == "true" ]] || return 0
    # An empty list is a kind given no versions rather than one the filter emptied.
    # The whole-matrix guard reports that against the enables.
    [[ "$(echo "$versions" | jq 'length')" -gt 0 ]] || return 0

    local runnable
    runnable=$(versions_above_minimum "$versions")
    if [[ "$(echo "$runnable" | jq 'length')" -eq 0 ]]; then
        fatal "$enable_name is set, but the minimum Swift version $min_swift_version removes every version in $versions_name ($(echo "$versions" | jq -r 'join(" ")')), so it would produce no jobs. $MINIMUM_VERSION_REMEDY"
    fi

    [[ -n "$commands_name" ]] || return 0
    if [[ -n "$unfiltered" ]]; then
        runnable=$(jq -c -n --argjson runnable "$runnable" --argjson unfiltered "$unfiltered" \
            '$unfiltered + $runnable')
    fi

    local entry label
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        # A label naming no versions of its own runs the kind's whole list, which
        # the check above covers.
        [[ "$(echo "$entry" | jq '.versions != null')" == "true" ]] || continue
        [[ "$(command_entry_versions "$entry" "$runnable" | jq 'length')" -eq 0 ]] || continue
        label=$(echo "$entry" | jq -r '.label')
        fatal "$commands_name label '$label' runs only on $(echo "$entry" | jq -r '.versions | join(" ")'), which the minimum Swift version $min_swift_version removes, so that label would produce no jobs while the others still run. $MINIMUM_VERSION_REMEDY"
    done < <(echo "$commands" | jq -c '.[]')
}

# Resolve a version label to the concrete toolchain identifier upstream uses.
# This is the Docker tag infix, the Windows installer script suffix, and the
# argument install-and-build-with-sdk.sh takes.
toolchain_for() {
    local version="$1"
    case "$version" in
        nightly-release|"nightly-${nightly_release_token}")
            echo "nightly-${nightly_release_token}"
            ;;
        *)
            echo "$version"
            ;;
    esac
}

# Resolve a version label to a swiftly selector. The branch token names the release
# snapshot's own directory under dev/, so it is passed through whole: swiftly's
# release-snapshot grammar takes a patch component, and "nightly-6.4.x" asks it for
# "6.4.x-snapshot".
swiftly_for() {
    local version="$1"
    local toolchain
    toolchain=$(toolchain_for "$version")
    case "$toolchain" in
        nightly-main)
            echo "main-snapshot"
            ;;
        nightly-*)
            echo "${toolchain#nightly-}-snapshot"
            ;;
        *)
            echo "$toolchain"
            ;;
    esac
}

# Build the swift_build object for a version label. The resolved forms are added
# only when they differ, so a hand-written matrix needs only `swift_version`.
swift_build_json() {
    local version="$1"
    local toolchain swiftly obj
    toolchain=$(toolchain_for "$version")
    swiftly=$(swiftly_for "$version")

    obj=$(jq -n -c --arg v "$version" '{swift_version: $v}')
    if [[ "$toolchain" != "$version" ]]; then
        obj=$(echo "$obj" | jq -c --arg t "$toolchain" '.toolchain = $t')
    fi
    if [[ "$swiftly" != "$version" ]]; then
        obj=$(echo "$obj" | jq -c --arg s "$swiftly" '.swiftly = $s')
    fi
    echo "$obj"
}

# Pick the newest non-nightly version from a JSON array. Falls back to the last
# element when the list contains only nightlies.
newest_release_version() {
    local versions_json="$1"
    local newest="" last=""
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        last="$v"
        [[ "$v" =~ ^nightly- ]] && continue
        if [[ -z "$newest" ]] || version_gte "$v" "$newest"; then
            newest="$v"
        fi
    done < <(echo "$versions_json" | jq -r '.[]')
    echo "${newest:-$last}"
}

# Attach the container configuration for an entry: the image for this version and
# OS, plus any Dockerfile, capabilities or security options the caller asked for.
add_container() {
    local entry="$1" version="$2" os="$3"
    local image
    image=$(linux_container_image "$version" "$os")
    echo "$entry" | jq -c \
        --arg image "$image" \
        --arg dockerfile "$linux_dockerfile" \
        --argjson capabilities "$linux_docker_capabilities" \
        --argjson security_options "$linux_docker_security_options" \
        '.swift_build.container = ({image: $image}
            + (if $dockerfile == "" then {} else {dockerfile: $dockerfile} end)
            + (if ($capabilities | length) == 0 then {} else {capabilities: $capabilities} end)
            + (if ($security_options | length) == 0 then {} else {security_options: $security_options} end))'
}

# Container image for a version label, which it resolves to a toolchain itself.
linux_container_image() {
    local version="$1" os="$2"
    local toolchain
    toolchain=$(toolchain_for "$version")
    if [[ "$toolchain" == nightly-* ]]; then
        echo "swiftlang/swift:${toolchain}-${os}"
    else
        echo "swift:${toolchain}-${os}"
    fi
}

# Container image tag for a Windows runner label.
#
# A Windows container shares the host's kernel, so an image built for another
# Windows release does not start on it. ltsc2022 is the only Swift Windows image
# named anywhere in this repository, so any other label fails rather than being
# paired with an image that cannot run there.
#
# $1 (string): the runner label, such as "windows-2022"
windows_container_tag() {
    local runner="$1"
    case "$runner" in
        windows-2022)
            echo "windowsservercore-ltsc2022"
            ;;
        *)
            fatal "No Swift Windows container image is known for $runner; windows_use_docker supports windows-2022. Other labels have to run natively."
            ;;
    esac
}

# Toolchain tarball for a FreeBSD OS version.
#
# The published tarballs are named by major release, and only 14 has one, so any
# other OS version would install a toolchain built for a release the job is not
# labeled for.
#
# $1 (string): the FreeBSD OS version, such as "14.3"
freebsd_toolchain_url() {
    local os_version="$1"
    case "$os_version" in
        14 | 14.*)
            echo "https://download.swift.org/tmp-ci-nightly/development/freebsd-14_ci_latest.tar.gz"
            ;;
        *)
            fatal "No Swift toolchain is published for FreeBSD $os_version; freebsd_os_versions supports 14 releases."
            ;;
    esac
}

# A per-version override is either a string — extra arguments, the common case —
# or an object with `arguments` and/or `command`. The object form lets a caller
# replace the whole command for one version, which some jobs need in order to
# work around a version-specific problem.
#
#   linux_version_overrides: |
#     6.2: -Xswiftc -warnings-as-errors
#     nightly-main:
#       command: swift build
#       arguments: --explicit-target-dependency-import-check error
version_override_arguments() {
    local version="$1" overrides_json="$2"
    echo "$overrides_json" | jq -r --arg v "$version" '
        .[$v] as $o
        | if $o == null then ""
          elif ($o | type) == "string" then $o
          else ($o.arguments // "") end'
}

version_override_command() {
    local version="$1" overrides_json="$2"
    echo "$overrides_json" | jq -r --arg v "$version" '
        .[$v] as $o
        | if ($o | type) == "object" then ($o.command // "") else "" end'
}

# Resolve the command for a version: its override if it has one, else the base.
command_for_version() {
    local version="$1" overrides_json="$2" base_command="$3"
    local override
    override=$(version_override_command "$version" "$overrides_json")
    if [[ -n "$override" ]]; then
        echo "$override"
    else
        echo "$base_command"
    fi
}

# Split a flag string on whitespace into a JSON array.
#
# Globbing is disabled first: a flag such as `--filter *Tests` would otherwise
# expand against the generator's own working directory and reach the runner as
# several arguments.
flags_to_json_array() {
    local args="$1"

    if [[ -z "$args" ]]; then
        echo "[]"
        return
    fi

    local json_array="[]" arg
    set -f
    for arg in $args; do
        json_array=$(echo "$json_array" | jq -c --arg a "$arg" '. + [$a]')
    done
    set +f
    echo "$json_array"
}

command_arguments_json() {
    local version="$1" overrides_json="$2"
    local args=""

    if [[ "$version" =~ ^nightly- ]]; then
        args="$swift_nightly_flags"
    else
        args="$swift_flags"
    fi

    local override
    override=$(version_override_arguments "$version" "$overrides_json")
    if [[ -n "$override" ]]; then
        args="$args $override"
    fi

    flags_to_json_array "$args"
}

# Validate that all keys in an overrides JSON exist in the given version list.
#
# A key naming no version contributes nothing, so the arguments it carries are
# silently lost and the job still passes. That is how a repository loses
# warnings-as-errors after renaming a version, so this is fatal rather than a
# warning.
validate_override_keys() {
    local overrides_json="$1" versions_json="$2" label="$3"

    if [[ "$overrides_json" == "{}" || -z "$overrides_json" ]]; then
        return
    fi

    # No versions means no job kind reading these overrides is enabled, so a key
    # names nothing because nothing runs. Failing there would take down the
    # platforms that are enabled over a setting none of them read.
    if [[ "$versions_json" == "[]" ]]; then
        log "WARNING: ignoring $label: no enabled job kind reads it"
        return
    fi

    local keys
    keys=$(echo "$overrides_json" | jq -r 'keys[]')
    local valid_versions
    valid_versions=$(echo "$versions_json" | jq -r '.[]')

    # Read whole lines: an unquoted expansion would split a key on its own
    # whitespace, and halves that each name a version would validate while the
    # override they carry matches nothing.
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if ! echo "$valid_versions" | grep -qxF "$key"; then
            fatal "$label override key '$key' does not match any version in the matrix. Valid keys: $(printf '%s' "$valid_versions" | tr '\n' ' ')"
        fi
    done <<< "$keys"
}

# Union of the version lists an overrides object can name, taking arguments in
# pairs: whether a job kind is enabled, then that kind's version list.
#
# The lists are independent — a release build or an SDK build can name a version
# the test sweep does not — so a key is valid if it names a version in any of
# them. A kind that is not enabled contributes none of its versions.
overridable_versions() {
    local result="[]"
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "true" ]]; then
            result=$(jq -c -n --argjson have "$result" --argjson add "$2" '$have + $add | unique')
        fi
        shift 2
    done
    echo "$result"
}

# Append an entry to the matrix JSON.
#
# $1 (string): The matrix so far
# $2 (string): The entry, as a JSON object
# Collects one entry. Appending to an array rather than rewriting the matrix keeps
# this linear: `.config += [$entry]` reparses and reserializes every entry already
# emitted, so the cost grew with the square of the matrix.
add_entry() {
    matrix_entries+=("$1")
}

# Emits the entries for one Linux job kind: one per version and command, fanned
# out over the axes that kind has. An axis the kind does not have is passed empty.
#
# $1 (string): "true" when the kind is enabled
# $2 (string): the version list, a JSON array
# $3 (string): the entry name, which the version is appended to
# $4 (string): the Swift SDK type, or empty for a build for the host
# $5 (string): the setup command
# $6 (string): the commands, as JSON
# $7 (string): the name of the input the commands came from, for an error message.
#              Empty says the kind's command is the check itself: a per-version
#              `command:` override replaces the caller's command, so one naming a
#              version this kind runs fails the run rather than leaving the name
#              saying what the job no longer does.
# $8 (string): the command arguments, a JSON array. Empty takes them from the
#              flags and linux_version_overrides for each version instead.
# $9 (string): the NDK releases to fan out over, a JSON array, or empty
# $10 (string): "true" to fan out over linux_os and containerize when
#              linux_use_docker is set. An SDK build takes
#              neither: install-and-build-with-sdk.sh fetches a toolchain matched
#              to the SDK itself, and job-runner-linux.sh fails an entry carrying
#              both an sdk and a container rather than build with the container's
#              own toolchain.
# $11 (string): JSON merged into each entry, or empty
emit_linux_job_kind() {
    local enabled="$1" versions="$2" name_prefix="$3" sdk_type="$4" setup_command="$5" \
        commands="$6" commands_name="$7" arguments="$8" ndk_versions="$9" \
        os_fanout="${10}" extra_fields="${11}"

    if [[ "$enabled" != "true" ]]; then
        return
    fi
    if [[ -z "$extra_fields" ]]; then
        extra_fields="{}"
    fi

    local overridden
    if [[ -n "$commands_name" ]]; then
        validate_one_command_to_override "$commands_name" "$commands" \
            "linux_version_overrides" "$linux_version_overrides" "$versions"
    else
        overridden=$(overridden_versions "$linux_version_overrides" "$versions")
        if [[ -n "$overridden" ]]; then
            fatal "linux_version_overrides replaces the command for $overridden, which \"$name_prefix\" also runs. Its command is the check itself, so replacing it would leave the job named for something it no longer does. Drop the command from the override, or take that version out of this kind's version list."
        fi
    fi

    # An axis the kind does not have is one pass whose value nothing reads.
    local os_list='["-"]' ndk_list='["-"]'
    if [[ "$os_fanout" == "true" ]]; then
        os_list="$linux_os_list"
    fi
    if [[ -n "$ndk_versions" ]]; then
        ndk_list="$ndk_versions"
    fi

    local command_count
    command_count=$(echo "$commands" | jq 'length')

    local os ndk version name sdk_json swift_build cmd_args entry
    local command_entry command_label base_command entry_command command_versions
    while IFS= read -r os; do
        [[ -n "$os" ]] || continue
        while IFS= read -r ndk; do
            [[ -n "$ndk" ]] || continue

            # An NDK release is part of which SDK a build is made against, so it
            # belongs in the descriptor beside the triples.
            if [[ -z "$sdk_type" ]]; then
                sdk_json="{}"
            elif [[ -z "$ndk_versions" ]]; then
                sdk_json=$(jq -n -c --arg type "$sdk_type" '{sdk: {type: $type}}')
            else
                sdk_json=$(jq -n -c --arg type "$sdk_type" --arg ndk "$ndk" \
                    --argjson triples "$android_sdk_triples" \
                    '{sdk: {type: $type, ndk_version: $ndk, triples: $triples}}')
            fi

            while IFS= read -r command_entry; do
                [[ -n "$command_entry" ]] || continue
                command_label=$(echo "$command_entry" | jq -r '.label')
                base_command=$(echo "$command_entry" | jq -r '.command')
                command_versions=$(command_entry_versions "$command_entry" "$versions")

                while IFS= read -r version; do
                    [[ -n "$version" ]] || continue
                    should_include_version "$version" || continue

                    name="$name_prefix $version"
                    if [[ -n "$ndk_versions" ]]; then
                        name="$name NDK $ndk"
                    fi
                    if [[ "$os_fanout" == "true" && "$linux_os_count" -gt 1 ]]; then
                        name="$name $os"
                    fi
                    if [[ "$command_count" -gt 1 ]]; then
                        name="$command_label $name"
                    fi

                    if [[ -n "$commands_name" ]]; then
                        entry_command=$(command_for_version "$version" "$linux_version_overrides" "$base_command")
                    else
                        entry_command="$base_command"
                    fi

                    swift_build=$(swift_build_json "$version")
                    if [[ -n "$arguments" ]]; then
                        cmd_args="$arguments"
                    else
                        cmd_args=$(command_arguments_json "$version" "$linux_version_overrides")
                    fi

                    entry=$(jq -n -c \
                        --arg name "$name" \
                        --argjson swift_build "$swift_build" \
                        --argjson sdk "$sdk_json" \
                        --arg setup_command "$setup_command" \
                        --arg command "$entry_command" \
                        --argjson command_arguments "$cmd_args" \
                        --argjson env "$linux_env_vars" \
                        --arg runner "$primary_linux_runner" \
                        --argjson extra_fields "$extra_fields" \
                        '{platform: "Linux", name: $name, runner: [$runner], swift_build: ($swift_build + $sdk), setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env} + $extra_fields')

                    if [[ "$os_fanout" == "true" && "$linux_use_docker" == "true" ]]; then
                        entry=$(add_container "$entry" "$version" "$os")
                    fi

                    add_entry "$entry"
                done < <(echo "$command_versions" | jq -r '.[]')
            done < <(echo "$commands" | jq -c '.[]')
        done < <(echo "$ndk_list" | jq -r '.[]')
    done < <(echo "$os_list" | jq -r '.[]')
}

# Emits the macOS entries for one version list on one OS: one per version and
# command.
#
# A label's versions select from this list, so a label naming only Xcode versions
# contributes nothing here and everything to the Xcode pass — which is what a
# caller who wrote an Xcode version asked for.
#
# $1 (string): the version list, a JSON array
# $2 (string): the OS, which becomes a runner label
# $3 (string): what the entry name carries between "macOS" and the version
# $4 (string): the xcode_build key naming the toolchain
# $5 (string): "true" to drop versions below the minimum Swift version
emit_macos_entries() {
    local versions_json="$1" os="$2" label="$3" version_key="$4" filter_minimum="$5"
    local version name cmd_args entry_command entry
    local command_entry command_label base_command command_versions command_count
    command_count=$(echo "$macos_commands" | jq 'length')
    while IFS= read -r command_entry; do
        [[ -n "$command_entry" ]] || continue
        command_label=$(echo "$command_entry" | jq -r '.label')
        base_command=$(echo "$command_entry" | jq -r '.command')
        command_versions=$(command_entry_versions "$command_entry" "$versions_json")

        while IFS= read -r version; do
            [[ -n "$version" ]] || continue
            if [[ "$filter_minimum" == "true" ]]; then
                should_include_version "$version" || continue
            fi

            name="macOS $label $version"
            if [[ "$macos_os_count" -gt 1 ]]; then
                name="$name $os"
            fi
            if [[ "$command_count" -gt 1 ]]; then
                name="$command_label $name"
            fi

            cmd_args=$(command_arguments_json "$version" "$macos_version_overrides")
            entry_command=$(command_for_version "$version" "$macos_version_overrides" "$base_command")

            entry=$(jq -n -c \
                --arg platform "macOS" \
                --arg name "$name" \
                --arg version_key "$version_key" \
                --arg version "$version" \
                --arg os "$os" \
                --arg arch "$macos_arch" \
                --arg setup_command "$macos_setup_command" \
                --arg command "$entry_command" \
                --argjson command_arguments "$cmd_args" \
                --argjson env "$macos_env_vars" \
                --arg pool "$macos_runner_pool" \
                --argjson xcode_targets "$xcode_targets" \
                --argjson debug_output "$xcode_debug_output" \
                '{platform: $platform, name: $name, runner: ["self-hosted", "macos", $os, $arch, $pool], xcode_build: ({($version_key): $version} + {targets: $xcode_targets, debug_output: $debug_output}), setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env}')

            add_entry "$entry"
        done < <(echo "$command_versions" | jq -r '.[]')
    done < <(echo "$macos_commands" | jq -c '.[]')
}

# Sets xcode_targets to the schema's xcode_build.targets array for the platforms
# the xcode_targets input named.
#
# The result is assigned rather than printed because an invalid target is fatal: a
# fatal reached from inside a command substitution prints its message and lets the
# run carry on without the target.
build_xcode_targets() {
    xcode_targets="[]"
    if [[ -z "$xcode_targets_input" ]]; then
        return
    fi

    local targets_map entry platform settings unknown_settings scheme
    local do_build do_test build_destination test_destination
    local default_build_destination default_test_destination

    # A scalar is rejected rather than read as one platform: the parse is here
    # only to tell a map from a list. The keys it yields have to match a platform
    # below, so YAML rewriting one cannot pass unnoticed.
    if ! input_is_collection "xcode_targets" "$xcode_targets_input"; then
        fatal "xcode_targets takes a map, such as {iOS: {build: true}}, or a list, such as [iOS, watchOS], but got: $xcode_targets_input"
    fi
    targets_map=$(yaml_to_json "$xcode_targets_input")

    if echo "$targets_map" | jq -e 'type == "array"' > /dev/null; then
        if ! echo "$targets_map" | jq -e 'all(type == "string")' > /dev/null; then
            fatal "xcode_targets as a list takes platform names, such as [iOS, watchOS], but got: $xcode_targets_input"
        fi
        # A list asks for each platform with every setting left at its default.
        targets_map=$(echo "$targets_map" | jq -c 'reduce .[] as $platform ({}; .[$platform] = {})')
    fi

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        platform=$(echo "$entry" | jq -r '.key')
        # A platform named with no settings is written `iOS:`, which parses as null.
        settings=$(echo "$entry" | jq -c 'if .value == null then {} else .value end')

        # The destinations below name the newest device of each kind, which ages
        # with every Xcode release — so a target can give its own instead.
        case "$platform" in
            macOS)
                default_build_destination="generic/platform=macos,variant=macos"
                default_test_destination="name=My Mac,variant=macos"
                ;;
            Catalyst)
                default_build_destination="generic/platform=macos,variant=Mac Catalyst"
                default_test_destination="name=My Mac,variant=Mac Catalyst"
                ;;
            iOS)
                default_build_destination="generic/platform=ios"
                default_test_destination="name=iPhone Air"
                ;;
            watchOS)
                default_build_destination="generic/platform=watchos"
                default_test_destination="name=Apple Watch Ultra 3 (49mm)"
                ;;
            tvOS)
                default_build_destination="generic/platform=tvos"
                default_test_destination="name=Apple TV 4K (3rd generation)"
                ;;
            visionOS)
                default_build_destination="generic/platform=visionos"
                default_test_destination="name=Apple Vision Pro"
                ;;
            *)
                fatal "xcode_targets names an unknown platform '$platform'; the platforms are macOS, Catalyst, iOS, watchOS, tvOS and visionOS."
                ;;
        esac

        if ! echo "$settings" | jq -e 'type == "object"' > /dev/null; then
            fatal "xcode_targets settings for $platform take the form {build: true, test: true}, but got: $settings"
        fi
        # A misspelled setting would otherwise be dropped and its default left in
        # place: a target carrying `sheme` would build the default scheme, or fail
        # for the want of one the caller supplied.
        unknown_settings=$(echo "$settings" | jq -r 'keys - ["build", "test", "scheme", "build_destination", "test_destination"] | join(", ")')
        if [[ -n "$unknown_settings" ]]; then
            fatal "xcode_targets settings for $platform include unknown keys: $unknown_settings. A target takes build, test, scheme, build_destination and test_destination."
        fi
        if ! echo "$settings" | jq -e '((.build // true) | type) == "boolean" and ((.test // false) | type) == "boolean"' > /dev/null; then
            fatal "xcode_targets settings for $platform take build and test as true or false, but got: $settings"
        fi

        # Building is the default because a package can be built for every
        # platform, while testing needs a simulator and takes far longer.
        do_build=$(echo "$settings" | jq -r 'if .build == null then true else .build end')
        do_test=$(echo "$settings" | jq -r 'if .test == null then false else .test end')
        if [[ "$do_build" != "true" && "$do_test" != "true" ]]; then
            fatal "xcode_targets asks for $platform with build and test both false, so the target would do nothing."
        fi

        scheme=$(echo "$settings" | jq -r --arg default "$xcode_scheme" '.scheme // $default')
        if [[ -z "$scheme" ]]; then
            fatal "xcode_targets names $platform but no scheme reaches it; set xcode_scheme, or give the target its own. xcodebuild builds nothing without a scheme."
        fi

        build_destination=$(echo "$settings" | jq -r --arg default "$default_build_destination" '.build_destination // $default')
        test_destination=$(echo "$settings" | jq -r --arg default "$default_test_destination" '.test_destination // $default')

        xcode_targets=$(echo "$xcode_targets" | jq -c \
            --arg platform "$platform" \
            --arg scheme "$scheme" \
            --arg build_destination "$build_destination" \
            --arg test_destination "$test_destination" \
            --argjson build "$do_build" \
            --argjson test "$do_test" \
            '. + [{platform: $platform, scheme: $scheme, build_destination: $build_destination, test_destination: $test_destination, build: $build, test: $test}]')
    done < <(echo "$targets_map" | jq -c 'to_entries[]')
}

# ===========================================================================
# Resolve minimum Swift version
# ===========================================================================
if [[ "$min_swift_version_input" == "none" ]]; then
    min_swift_version="none"
elif [[ -n "$min_swift_version_input" ]]; then
    min_swift_version="$min_swift_version_input"
else
    min_swift_version=$(find_minimum_swift_version)
    if [[ -n "$min_swift_version" ]]; then
        log "Auto-detected minimum Swift tools version: $min_swift_version"
    fi
fi

# ===========================================================================
# Resolve the release-build and Cxx-interop version lists
# ===========================================================================
# Both default to a single version — the newest release in the Linux list —
# because they are supplementary checks rather than a compatibility sweep.
# Pass an explicit list to run them across more versions.
cxx_interop_versions="${CXX_INTEROP_SWIFT_VERSIONS:-}"
if [[ -n "$cxx_interop_versions" ]]; then
    cxx_interop_versions=$(to_json_array "cxx_interop_swift_versions" "$cxx_interop_versions")
else
    cxx_interop_versions=$(jq -n -c --arg v "$(newest_release_version "$linux_swift_versions")" '[$v]')
fi

# ===========================================================================
# Resolve the xcodebuild targets
# ===========================================================================
# Resolved before the owner guard runs, so a fork — which gets no macOS entries at
# all — still reports a target the caller got wrong.
build_xcode_targets

# ===========================================================================
# Build the matrix
# ===========================================================================

linux_all_versions=$(overridable_versions \
    "$enable_linux" "$linux_swift_versions" \
    "$enable_cxx_interop" "$cxx_interop_versions" \
    "$enable_linux_static_sdk" "$linux_static_sdk_versions" \
    "$enable_wasm_sdk" "$wasm_sdk_versions" \
    "$enable_embedded_wasm_sdk" "$embedded_wasm_sdk_versions")
macos_all_versions=$(overridable_versions \
    "$enable_macos" "${macos_swift_versions:-[]}" \
    "$enable_macos" "${macos_xcode_versions:-[]}")
windows_all_versions=$(overridable_versions "$enable_windows" "$windows_swift_versions")

validate_override_keys "$linux_version_overrides" "$linux_all_versions" "linux_version_overrides"
validate_override_keys "$windows_version_overrides" "$windows_all_versions" "windows_version_overrides"
validate_override_keys "$macos_version_overrides" "$macos_all_versions" "macos_version_overrides"

validate_command_versions "$enable_linux"             "linux_command"             "$linux_commands"             "$linux_swift_versions"
validate_command_versions "$enable_windows"           "windows_command"           "$windows_commands"           "$windows_swift_versions"
validate_command_versions "$enable_macos"             "macos_command"             "$macos_commands"             "$macos_all_versions"
validate_command_versions "$enable_freebsd"           "freebsd_command"           "$freebsd_commands"           "$freebsd_swift_versions"
validate_command_versions "$enable_linux_static_sdk"  "linux_static_sdk_command"  "$linux_static_sdk_commands"  "$linux_static_sdk_versions"
validate_command_versions "$enable_wasm_sdk"          "wasm_sdk_command"          "$wasm_sdk_commands"          "$wasm_sdk_versions"
validate_command_versions "$enable_embedded_wasm_sdk" "embedded_wasm_sdk_command" "$embedded_wasm_sdk_commands" "$embedded_wasm_sdk_versions"
validate_command_versions "$enable_android_sdk"       "android_sdk_command"       "$android_sdk_commands"       "$android_sdk_versions"

if [[ "$enable_linux" == "true" ]]; then
    validate_one_command_to_override "linux_command" "$linux_commands" \
        "linux_version_overrides" "$linux_version_overrides" "$linux_swift_versions"
fi
if [[ "$enable_windows" == "true" ]]; then
    validate_one_command_to_override "windows_command" "$windows_commands" \
        "windows_version_overrides" "$windows_version_overrides" "$windows_swift_versions"
fi
if [[ "$enable_macos" == "true" ]]; then
    validate_one_command_to_override "macos_command" "$macos_commands" \
        "macos_version_overrides" "$macos_version_overrides" "$macos_all_versions"
fi

# macOS entries run on self-hosted pools. A fork has no access to them,
# so its jobs would queue until they time out. When macos_repository_owner is set
# and does not match, no macOS entries are generated — which produces no jobs
# rather than jobs that cannot start.
#
# The checks a caller's own mistake fails run above this, so a fork still reports
# one; the checks below take a suppressed macOS as a kind that is not enabled,
# because this repository did not ask for it.
if [[ "$enable_macos" == "true" || "$enable_macos_swiftly" == "true" ]] \
   && [[ -n "$macos_repository_owner" && -n "$github_repository_owner" ]] \
   && [[ "$macos_repository_owner" != "$github_repository_owner" ]]; then
    log "Skipping macOS entries: this repository's owner ($github_repository_owner) is not $macos_repository_owner"
    enable_macos="false"
    enable_macos_swiftly="false"
fi

# minimum-version filter
#                         enabled                     the enable input                 the versions input           that kind's versions          the command input           its commands                  any versions a label may select that the filter does not see
require_runnable_versions "$enable_linux"             "enable_linux"                   "linux_swift_versions"       "$linux_swift_versions"       "linux_command"             "$linux_commands"             ""
require_runnable_versions "$enable_macos"             "enable_macos"                   "macos_swift_versions"       "${macos_swift_versions:-[]}" "macos_command"             "$macos_commands"             "${macos_xcode_versions:-[]}"
require_runnable_versions "$enable_windows"           "enable_windows"                 "windows_swift_versions"     "$windows_swift_versions"     "windows_command"           "$windows_commands"           ""
require_runnable_versions "$enable_linux_static_sdk"  "enable_linux_static_sdk_build"  "linux_static_sdk_versions"  "$linux_static_sdk_versions"  "linux_static_sdk_command"  "$linux_static_sdk_commands"  ""
require_runnable_versions "$enable_wasm_sdk"          "enable_wasm_sdk_build"          "wasm_sdk_versions"          "$wasm_sdk_versions"          "wasm_sdk_command"          "$wasm_sdk_commands"          ""
require_runnable_versions "$enable_embedded_wasm_sdk" "enable_embedded_wasm_sdk_build" "embedded_wasm_sdk_versions" "$embedded_wasm_sdk_versions" "embedded_wasm_sdk_command" "$embedded_wasm_sdk_commands" ""
require_runnable_versions "$enable_android_sdk"       "enable_android_sdk_build"       "android_sdk_versions"       "$android_sdk_versions"       "android_sdk_command"       "$android_sdk_commands"       ""
require_runnable_versions "$enable_cxx_interop"       "enable_cxx_interop"             "cxx_interop_swift_versions" "$cxx_interop_versions"       ""                          ""                            ""

matrix_entries=()

# ---------------------------------------------------------------------------
# Linux entries
# ---------------------------------------------------------------------------
if [[ "$enable_linux" == "true" ]]; then
    linux_command_count=$(echo "$linux_commands" | jq 'length')
    while IFS= read -r arch; do
        [[ -n "$arch" ]] || continue
        local_runner=$(linux_runner_for_arch "$arch")

        while IFS= read -r os; do
            [[ -n "$os" ]] || continue
            while IFS= read -r command_entry; do
                [[ -n "$command_entry" ]] || continue
                command_label=$(echo "$command_entry" | jq -r '.label')
                base_command=$(echo "$command_entry" | jq -r '.command')
                command_versions=$(command_entry_versions "$command_entry" "$linux_swift_versions")

                while IFS= read -r version; do
                    [[ -n "$version" ]] || continue
                    should_include_version "$version" || continue

                    swift_build=$(swift_build_json "$version")
                    cmd_args=$(command_arguments_json "$version" "$linux_version_overrides")
                    entry_command=$(command_for_version "$version" "$linux_version_overrides" "$base_command")

                    name="Linux Swift $version"
                    if [[ "$linux_os_count" -gt 1 ]]; then
                        name="$name $os"
                    fi
                    if [[ "$arch_count" -gt 1 ]]; then
                        name="$name $arch"
                    fi
                    if [[ "$linux_command_count" -gt 1 ]]; then
                        name="$command_label $name"
                    fi

                    entry=$(jq -n -c \
                        --arg platform "Linux" \
                        --arg name "$name" \
                        --argjson swift_build "$swift_build" \
                        --arg setup_command "$linux_setup_command" \
                        --arg command "$entry_command" \
                        --argjson command_arguments "$cmd_args" \
                        --argjson env "$linux_env_vars" \
                        --arg runner "$local_runner" \
                        '{platform: $platform, name: $name, runner: [$runner], swift_build: $swift_build, setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env}')

                    if [[ "$linux_use_docker" == "true" ]]; then
                        entry=$(add_container "$entry" "$version" "$os")
                    fi

                    add_entry "$entry"
                done < <(echo "$command_versions" | jq -r '.[]')
            done < <(echo "$linux_commands" | jq -c '.[]')
        done < <(echo "$linux_os_list" | jq -r '.[]')
    done < <(echo "$linux_host_archs" | jq -r '.[]')
fi

# ---------------------------------------------------------------------------
# macOS entries
# ---------------------------------------------------------------------------
if [[ "$enable_macos" == "true" ]]; then
    while IFS= read -r os; do
        [[ -n "$os" ]] || continue

        if [[ -n "$macos_xcode_versions" ]]; then
            emit_macos_entries "$macos_xcode_versions" "$os" "Xcode" "xcode_version" "false"
        fi

        if [[ -n "$macos_swift_versions" ]]; then
            emit_macos_entries "$macos_swift_versions" "$os" "Swift" "swift_version" "true"
        fi
    done < <(echo "$macos_os_list" | jq -r '.[]')
fi

# ---------------------------------------------------------------------------
# macOS entries using a swiftly-managed toolchain
# ---------------------------------------------------------------------------
if [[ "$enable_macos_swiftly" == "true" ]]; then
    macos_swiftly_command_count=$(echo "$macos_swiftly_commands" | jq 'length')
    while IFS= read -r toolchain; do
        [[ -n "$toolchain" ]] || continue

        swiftly_xcode=$(echo "$toolchain" | jq -r '.xcode_version // empty')
        swiftly_version=$(echo "$toolchain" | jq -r '.swiftly_toolchain // empty')
        swiftly_arch=$(echo "$toolchain" | jq -r --arg d "$macos_arch" '.arch // $d')

        # Skipping the entry would drop a job from a run that still reports
        # success, which is how a misspelled key goes unnoticed.
        if [[ -z "$swiftly_xcode" || -z "$swiftly_version" ]]; then
            fatal "macos_swiftly_toolchains entry needs both xcode_version and swiftly_toolchain: $toolchain"
        fi

        # Snapshots take the nightly flags, matching how the version lists treat
        # a "nightly-" prefix elsewhere.
        if [[ "$swiftly_version" == *snapshot* ]]; then
            swiftly_args="$swift_nightly_flags"
        else
            swiftly_args="$swift_flags"
        fi
        swiftly_cmd_args=$(flags_to_json_array "$swiftly_args")

        # An entry naming its own OS runs on that one alone; the rest fan out over
        # macos_os as the other macOS blocks do.
        swiftly_os_list=$(echo "$toolchain" | jq -c --argjson list "$macos_os_list" \
            'if (.os_version // "") == "" then $list else [.os_version] end')

        while IFS= read -r swiftly_os; do
            [[ -n "$swiftly_os" ]] || continue
            while IFS= read -r command_entry; do
                [[ -n "$command_entry" ]] || continue
                command_label=$(echo "$command_entry" | jq -r '.label')
                base_command=$(echo "$command_entry" | jq -r '.command')

                name="macOS Swiftly $swiftly_version (Xcode $swiftly_xcode)"
                if [[ "$macos_os_count" -gt 1 ]]; then
                    name="$name $swiftly_os"
                fi
                if [[ "$macos_swiftly_command_count" -gt 1 ]]; then
                    name="$command_label $name"
                fi

                entry=$(jq -n -c \
                    --arg platform "macOS" \
                    --arg name "$name" \
                    --arg xcode_version "$swiftly_xcode" \
                    --arg swiftly_toolchain "$swiftly_version" \
                    --arg os "$swiftly_os" \
                    --arg arch "$swiftly_arch" \
                    --arg setup_command "$macos_setup_command" \
                    --arg command "$base_command" \
                    --argjson command_arguments "$swiftly_cmd_args" \
                    --argjson env "$macos_env_vars" \
                    --arg pool "$macos_runner_pool" \
                    '{platform: $platform, name: $name, runner: ["self-hosted", "macos", $os, $arch, $pool], xcode_build: {xcode_version: $xcode_version, swiftly_toolchain: $swiftly_toolchain}, setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env}')

                add_entry "$entry"
            done < <(echo "$macos_swiftly_commands" | jq -c '.[]')
        done < <(echo "$swiftly_os_list" | jq -r '.[]')
    done < <(echo "$macos_swiftly_toolchains" | jq -c '.[]')
fi

# ---------------------------------------------------------------------------
# Windows entries
# ---------------------------------------------------------------------------
if [[ "$enable_windows" == "true" ]]; then
    windows_command_count=$(echo "$windows_commands" | jq 'length')
    while IFS= read -r os_version; do
        [[ -n "$os_version" ]] || continue
        while IFS= read -r command_entry; do
            [[ -n "$command_entry" ]] || continue
            command_label=$(echo "$command_entry" | jq -r '.label')
            base_command=$(echo "$command_entry" | jq -r '.command')
            command_versions=$(command_entry_versions "$command_entry" "$windows_swift_versions")

            while IFS= read -r version; do
                [[ -n "$version" ]] || continue
                should_include_version "$version" || continue

                swift_build=$(swift_build_json "$version")
                cmd_args=$(command_arguments_json "$version" "$windows_version_overrides")
                entry_command=$(command_for_version "$version" "$windows_version_overrides" "$base_command")

                windows_os_count=$(echo "$windows_os_list" | jq 'length')
                name="Windows Swift $version"
                if [[ "$windows_os_count" -gt 1 ]]; then
                    name="$name $os_version"
                fi
                if [[ "$windows_command_count" -gt 1 ]]; then
                    name="$command_label $name"
                fi

                entry=$(jq -n -c \
                    --arg platform "Windows" \
                    --arg name "$name" \
                    --argjson swift_build "$swift_build" \
                    --arg setup_command "$windows_setup_command" \
                    --arg command "$entry_command" \
                    --argjson command_arguments "$cmd_args" \
                    --argjson env "$windows_env_vars" \
                    --arg runner "$os_version" \
                    '{platform: $platform, name: $name, runner: [$runner], swift_build: $swift_build, setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env}')

                if [[ "$windows_use_docker" == "true" ]]; then
                    windows_toolchain=$(toolchain_for "$version")
                    container_tag=$(windows_container_tag "$os_version")
                    if [[ "$windows_toolchain" == nightly-* ]]; then
                        image="swiftlang/swift:${windows_toolchain}-${container_tag}"
                    else
                        image="swift:${windows_toolchain}-${container_tag}"
                    fi
                    entry=$(echo "$entry" | jq -c --arg image "$image" '.swift_build.container = {image: $image}')
                fi

                add_entry "$entry"
            done < <(echo "$command_versions" | jq -r '.[]')
        done < <(echo "$windows_commands" | jq -c '.[]')
    done < <(echo "$windows_os_list" | jq -r '.[]')
fi

# ===========================================================================
# SDK build, release build and Cxx interop entries
# ===========================================================================
# The emulator runs what the SDK build produced, so that build has to be told to
# produce test binaries, and the entry has to carry the flag the executor reads.
if [[ "$enable_android_emulator_tests" == "true" ]]; then
    android_sdk_command_arguments='["--build-tests"]'
    android_sdk_extra_fields='{"android_emulator": true}'
else
    android_sdk_command_arguments='[]'
    android_sdk_extra_fields='{"android_emulator": false}'
fi

#                   enabled                     versions                      name                     sdk              setup_command                      commands                      command input               arguments                        ndk_versions            linux_os extra_fields
emit_linux_job_kind "$enable_linux_static_sdk"  "$linux_static_sdk_versions"  "Static Linux SDK Swift"  "static-linux"  "$linux_static_sdk_setup_command"  "$linux_static_sdk_commands"  "linux_static_sdk_command"  ""                               ""                      "false"  ""
emit_linux_job_kind "$enable_wasm_sdk"          "$wasm_sdk_versions"          "Wasm SDK Swift"          "wasm"          "$wasm_sdk_setup_command"          "$wasm_sdk_commands"          "wasm_sdk_command"          ""                               ""                      "false"  ""
emit_linux_job_kind "$enable_embedded_wasm_sdk" "$embedded_wasm_sdk_versions" "Embedded Wasm SDK Swift" "embedded-wasm" "$embedded_wasm_sdk_setup_command" "$embedded_wasm_sdk_commands" "embedded_wasm_sdk_command" ""                               ""                      "false"  ""
emit_linux_job_kind "$enable_android_sdk"       "$android_sdk_versions"       "Android SDK Swift"       "android"       "$android_sdk_setup_command"       "$android_sdk_commands"       "android_sdk_command"       "$android_sdk_command_arguments" "$android_ndk_versions" "false"  "$android_sdk_extra_fields"
emit_linux_job_kind "$enable_cxx_interop"       "$cxx_interop_versions"       "Cxx interop Swift"       ""              "$linux_setup_command"             "$cxx_interop_commands"        ""                         ""                               ""                      "true"   ""

# ===========================================================================
# FreeBSD entries
# ===========================================================================
if [[ "$enable_freebsd" == "true" ]]; then
    freebsd_command_count=$(echo "$freebsd_commands" | jq 'length')
    while IFS= read -r os_ver; do
        [[ -n "$os_ver" ]] || continue
        while IFS= read -r command_entry; do
            [[ -n "$command_entry" ]] || continue
            command_label=$(echo "$command_entry" | jq -r '.label')
            base_command=$(echo "$command_entry" | jq -r '.command')
            command_versions=$(command_entry_versions "$command_entry" "$freebsd_swift_versions")

            while IFS= read -r version; do
                [[ -n "$version" ]] || continue

                # One FreeBSD toolchain is published and its URL is fixed, so a
                # version naming anything else would produce a job labeled for a
                # toolchain it does not install.
                if [[ "$version" != "nightly-main" ]]; then
                    fatal "FreeBSD supports only the nightly-main Swift version, not '$version'."
                fi

                swift_url=$(freebsd_toolchain_url "$os_ver")

                name="FreeBSD $version - $os_ver - x86_64"
                if [[ "$freebsd_command_count" -gt 1 ]]; then
                    name="$command_label $name"
                fi

                entry=$(jq -n -c \
                    --arg platform "FreeBSD" \
                    --arg name "$name" \
                    --arg os_version "$os_ver" \
                    --arg swift_version "$version" \
                    --arg swift_url "$swift_url" \
                    --arg build_flags "$swift_nightly_flags" \
                    --arg env_vars "$freebsd_env_vars" \
                    --arg setup_command "$freebsd_setup_command" \
                    --arg command "$base_command" \
                    '{platform: $platform, name: $name, runner: ["ubuntu-24.04"], freebsd: {os_version: $os_version, swift_version: $swift_version, swift_url: $swift_url, build_flags: $build_flags, env_vars: $env_vars}, setup_command: $setup_command, command: $command, command_arguments: [], env: {}}')

                add_entry "$entry"
            done < <(echo "$command_versions" | jq -r '.[]')
        done < <(echo "$freebsd_commands" | jq -c '.[]')
    done < <(echo "$freebsd_os_versions" | jq -r '.[]')
fi

# ===========================================================================
# Output
# ===========================================================================
# One serialization of everything collected. The array guard is for bash 3.2, where
# an empty array under `set -u` is an error rather than nothing.
if [[ ${#matrix_entries[@]} -eq 0 ]]; then
    matrix='{"config":[]}'
else
    matrix=$(printf '%s\n' "${matrix_entries[@]}" | jq -s -c '{config: .}')
fi

if [[ "$matrix_mode" == "toolchains" ]]; then
    # Drop what a caller supplies instead. env is kept, since it describes the
    # environment a toolchain needs rather than the work being run in it.
    matrix=$(echo "$matrix" | jq -c '.config |= map(del(.command, .setup_command, .command_arguments))')
fi

entry_count=${#matrix_entries[@]}

# An empty matrix is legitimate when nothing is enabled, and a mistake when
# something is: the versions were all filtered out, or a list was empty.
#
# The enables are read as they stand, so a deliberate skip — the fork guard, or
# toolchains mode clearing the command-only kinds — counts as not enabled.
enabled_kinds=()
for kind in \
    "enable_linux:enable_linux" \
    "enable_macos:enable_macos" \
    "enable_macos_swiftly:enable_macos_swiftly" \
    "enable_windows:enable_windows" \
    "enable_freebsd:enable_freebsd" \
    "enable_linux_static_sdk_build:enable_linux_static_sdk" \
    "enable_wasm_sdk_build:enable_wasm_sdk" \
    "enable_embedded_wasm_sdk_build:enable_embedded_wasm_sdk" \
    "enable_android_sdk_build:enable_android_sdk" \
    "enable_cxx_interop:enable_cxx_interop"
do
    input_name="${kind%%:*}"
    variable_name="${kind##*:}"
    if [[ "${!variable_name}" == "true" ]]; then
        enabled_kinds+=("$input_name")
    fi
done

if [[ "$entry_count" -eq 0 ]]; then
    if [[ ${#enabled_kinds[@]} -gt 0 ]]; then
        fatal "No matrix entries, but these are enabled: ${enabled_kinds[*]}. Check the version lists and minimum_swift_version — every version may have been filtered out."
    fi
    log "No matrix entries: nothing is enabled"
else
    log "Generated $entry_count matrix entries"
fi

if [[ "$matrix_format" == "json" ]]; then
    echo "$matrix" | jq .
else
    echo "$matrix" | yq -P
fi
