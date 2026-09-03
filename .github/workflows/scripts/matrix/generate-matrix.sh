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

# Both are checked up front so a missing tool is one clear message rather than a
# failure part-way through a matrix. They are called by name, not through a
# variable: shellcheck recognises jq and yq literally and only then knows their
# single-quoted filters are not shell expansions.
command -v jq >/dev/null || fatal "jq not found on PATH"
command -v yq >/dev/null || fatal "yq not found on PATH"

# Normalize a YAML or JSON value to JSON. Passes JSON through unchanged.
to_json() { echo "$1" | yq -o=json; }

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
enable_android_sdk_checks="${ENABLE_ANDROID_SDK_CHECKS:-false}"
enable_release_build="${ENABLE_RELEASE_BUILD:-false}"
enable_cxx_interop="${ENABLE_CXX_INTEROP:-false}"
enable_freebsd="${ENABLE_FREEBSD:-false}"
freebsd_swift_versions=$(to_json "${FREEBSD_SWIFT_VERSIONS:-"[\"nightly-main\"]"}")
freebsd_os_versions=$(to_json "${FREEBSD_OS_VERSIONS:-"[\"14.3\"]"}")
freebsd_build_command="${FREEBSD_BUILD_COMMAND:-swift test}"
freebsd_pre_build_command="${FREEBSD_PRE_BUILD_COMMAND:-}"
freebsd_env_vars="${FREEBSD_ENV_VARS:-}"

# ---------------------------------------------------------------------------
# Version lists (JSON arrays)
# ---------------------------------------------------------------------------

# nightly-release is an alias for the nightly of the next Swift release branch.
#
# The token below is the branch spelling upstream publishes under, and it is
# data rather than something derived from the version number: 6.0 through 6.3
# were "6.<n>", 6.4 is "6.4.x". It feeds the Docker tag
# (swiftlang/swift:nightly-<token>-<os>), the Windows installer script name,
# and the swift.org download and API paths the SDK script uses. Change it when
# a new release branch is cut; the "nightly-release" label callers write does
# not change, so nothing keyed on the label has to move.
nightly_release_token="${NIGHTLY_RELEASE_TOKEN:-6.4.x}"

default_linux_versions='["6.1", "6.2", "6.3", "nightly-release", "nightly-main"]'
default_macos_swift_versions='["6.1", "6.2", "6.3"]'
default_windows_versions='["6.1", "6.2", "6.3", "nightly-release", "nightly-main"]'
default_sdk_versions='["6.3", "nightly-release", "nightly-main"]'
default_android_versions='["6.3", "nightly-release", "nightly-main"]'
default_android_triples='["aarch64-unknown-linux-android28", "x86_64-unknown-linux-android28"]'

linux_swift_versions=$(to_json "${LINUX_SWIFT_VERSIONS:-$default_linux_versions}")
linux_os_versions="${LINUX_OS_VERSIONS:-}"
linux_os="${LINUX_OS:-noble}"
linux_host_archs=$(to_json "${LINUX_HOST_ARCHS:-"[\"x86_64\"]"}")
linux_use_docker="${LINUX_USE_DOCKER:-false}"
# Docker knobs the runner script supports but nothing could reach from the
# high-level workflows.
linux_dockerfile="${LINUX_DOCKERFILE:-}"
linux_docker_capabilities=$(to_json "${LINUX_DOCKER_CAPABILITIES:-"[]"}")
linux_docker_security_opts=$(to_json "${LINUX_DOCKER_SECURITY_OPTS:-"[]"}")
# A Dockerfile is built from a base image, so it implies container mode.
if [[ -n "$linux_dockerfile" ]]; then
    linux_use_docker="true"
fi
# If LINUX_OS_VERSIONS is a JSON array, use it; otherwise use single LINUX_OS
if [[ -n "$linux_os_versions" ]]; then
    linux_os_list=$(to_json "$linux_os_versions")
    # Multiple OS versions require Docker
    linux_use_docker="true"
else
    linux_os_list="[\"$linux_os\"]"
fi
os_count=$(echo "$linux_os_list" | jq 'length')
arch_count=$(echo "$linux_host_archs" | jq 'length')
macos_xcode_versions="${MACOS_XCODE_VERSIONS:-}"
macos_swift_versions="${MACOS_SWIFT_VERSIONS:-}"
# Default to Swift versions if neither is specified
if [[ -z "$macos_xcode_versions" && -z "$macos_swift_versions" ]]; then
    macos_swift_versions="$default_macos_swift_versions"
fi
if [[ -n "$macos_xcode_versions" ]]; then
    macos_xcode_versions=$(to_json "$macos_xcode_versions")
fi
if [[ -n "$macos_swift_versions" ]]; then
    macos_swift_versions=$(to_json "$macos_swift_versions")
fi
macos_os="${MACOS_OS:-tahoe}"
macos_versions="${MACOS_VERSIONS:-}"
if [[ -n "$macos_versions" ]]; then
    macos_os_list=$(to_json "$macos_versions")
else
    macos_os_list="[\"$macos_os\"]"
fi
macos_arch="${MACOS_ARCH:-ARM64}"
macos_runner_pool="${MACOS_RUNNER_POOL:-general}"
# Owner whose self-hosted macOS pools these entries require. Empty means no check.
macos_repository_owner="${MACOS_REPOSITORY_OWNER:-}"
github_repository_owner="${GITHUB_REPOSITORY_OWNER:-}"
xcode_debug_output="${XCODE_DEBUG_OUTPUT:-false}"
# macOS entries driven by a swiftly-managed toolchain rather than the Xcode that
# ships one. Each entry pairs an Xcode with a swiftly selector.
enable_macos_swiftly="${ENABLE_MACOS_SWIFTLY:-false}"
default_macos_swiftly_toolchains='[{"xcode_version": "swift_6.3", "swift_version": "main-snapshot"}]'
macos_swiftly_toolchains=$(to_json "${MACOS_SWIFTLY_TOOLCHAINS:-$default_macos_swiftly_toolchains}")
macos_swiftly_build_command="${MACOS_SWIFTLY_BUILD_COMMAND:-swiftly run swift test}"
windows_swift_versions=$(to_json "${WINDOWS_SWIFT_VERSIONS:-$default_windows_versions}")
windows_os_versions=$(to_json "${WINDOWS_OS_VERSIONS:-"[\"windows-2022\"]"}")
linux_static_sdk_versions=$(to_json "${LINUX_STATIC_SDK_VERSIONS:-$default_sdk_versions}")
wasm_sdk_versions=$(to_json "${WASM_SDK_VERSIONS:-$default_sdk_versions}")
embedded_wasm_sdk_versions=$(to_json "${EMBEDDED_WASM_SDK_VERSIONS:-$default_sdk_versions}")
android_sdk_versions=$(to_json "${ANDROID_SDK_VERSIONS:-$default_android_versions}")
android_ndk_versions=$(to_json "${ANDROID_NDK_VERSIONS:-"[\"r27d\"]"}")
android_triples=$(to_json "${ANDROID_TRIPLES:-$default_android_triples}")

# ---------------------------------------------------------------------------
# Commands & flags
# ---------------------------------------------------------------------------
linux_build_command="${LINUX_BUILD_COMMAND:-swift test}"
linux_pre_build_command="${LINUX_PRE_BUILD_COMMAND:-}"
macos_build_command="${MACOS_BUILD_COMMAND:-xcrun swift test}"
macos_pre_build_command="${MACOS_PRE_BUILD_COMMAND:-}"
windows_build_command="${WINDOWS_BUILD_COMMAND:-swift test}"
windows_pre_build_command="${WINDOWS_PRE_BUILD_COMMAND:-}"
linux_static_sdk_build_command="${LINUX_STATIC_SDK_BUILD_COMMAND:-swift build}"
linux_static_sdk_pre_build_command="${LINUX_STATIC_SDK_PRE_BUILD_COMMAND:-}"
wasm_sdk_build_command="${WASM_SDK_BUILD_COMMAND:-swift build}"
wasm_sdk_pre_build_command="${WASM_SDK_PRE_BUILD_COMMAND:-}"
embedded_wasm_sdk_build_command="${EMBEDDED_WASM_SDK_BUILD_COMMAND:-swift build}"
android_sdk_build_command="${ANDROID_SDK_BUILD_COMMAND:-swift build}"
android_sdk_pre_build_command="${ANDROID_SDK_PRE_BUILD_COMMAND:-}"
swift_flags="${SWIFT_FLAGS:-}"
swift_nightly_flags="${SWIFT_NIGHTLY_FLAGS:-}"

# Per-version argument overrides (JSON object: {"6.2": "-Xswiftc ...", ...})
linux_version_overrides=$(to_json "${LINUX_VERSION_OVERRIDES:-"{}"}")
windows_version_overrides=$(to_json "${WINDOWS_VERSION_OVERRIDES:-"{}"}")
macos_version_overrides=$(to_json "${MACOS_VERSION_OVERRIDES:-"{}"}")

# ---------------------------------------------------------------------------
# Environment variables (JSON objects)
# ---------------------------------------------------------------------------
linux_env_vars=$(to_json "${LINUX_ENV_VARS:-"{}"}")
macos_env_vars=$(to_json "${MACOS_ENV_VARS:-"{}"}")
windows_env_vars=$(to_json "${WINDOWS_ENV_VARS:-"{}"}")

# ---------------------------------------------------------------------------
# Xcodebuild platform targets (macOS jobs only)
# ---------------------------------------------------------------------------
xcode_scheme="${XCODE_SCHEME:-}"
enable_macos_xcode_build="${ENABLE_MACOS_XCODE_BUILD:-false}"
enable_macos_xcode_test="${ENABLE_MACOS_XCODE_TEST:-false}"
enable_catalyst_xcode_build="${ENABLE_CATALYST_XCODE_BUILD:-false}"
enable_catalyst_xcode_test="${ENABLE_CATALYST_XCODE_TEST:-false}"
enable_ios_xcode_build="${ENABLE_IOS_XCODE_BUILD:-false}"
enable_ios_xcode_test="${ENABLE_IOS_XCODE_TEST:-false}"
enable_watchos_xcode_build="${ENABLE_WATCHOS_XCODE_BUILD:-false}"
enable_watchos_xcode_test="${ENABLE_WATCHOS_XCODE_TEST:-false}"
enable_tvos_xcode_build="${ENABLE_TVOS_XCODE_BUILD:-false}"
enable_tvos_xcode_test="${ENABLE_TVOS_XCODE_TEST:-false}"
enable_visionos_xcode_build="${ENABLE_VISIONOS_XCODE_BUILD:-false}"
enable_visionos_xcode_test="${ENABLE_VISIONOS_XCODE_TEST:-false}"

# ---------------------------------------------------------------------------
# Docker/container mode
# ---------------------------------------------------------------------------
windows_use_docker="${ENABLE_WINDOWS_DOCKER:-false}"

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
        enable_android_sdk_checks="false"
        enable_release_build="false"
        enable_cxx_interop="false"
        enable_freebsd="false"
        ;;
    *)
        fatal "MATRIX_MODE must be 'jobs' or 'toolchains', got '$matrix_mode'"
        ;;
esac

# The matrix is assembled as JSON, and YAML is a conversion applied on the way
# out for the workflows that pass it around as a string. A caller that would only
# convert it back — anything decoding it programmatically — can ask for JSON and
# skip both conversions.
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
min_swift_version_input="${MATRIX_MIN_SWIFT_VERSION:-}"
find_subdirectory_manifests="${FIND_SUBDIRECTORY_MANIFESTS_ENABLED:-false}"

# ===========================================================================
# Utility functions
# ===========================================================================

version_gte() {
    local v1="$1" v2="$2"
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

# Resolve a version label to a swiftly selector. swiftly accepts only
# major.minor for release snapshots, so a "6.4.x" branch token becomes "6.4".
swiftly_for() {
    local version="$1"
    local toolchain
    toolchain=$(toolchain_for "$version")
    case "$toolchain" in
        nightly-main)
            echo "main-snapshot"
            ;;
        nightly-*)
            local branch="${toolchain#nightly-}"
            echo "${branch%.x}-snapshot"
            ;;
        *)
            echo "$toolchain"
            ;;
    esac
}

# Build the swift_build object for a version label. The label stays in
# `version`, since that is what SWIFT_VERSION, the per-version override keys and
# adopters' version-keyed directories all use. The resolved forms are added only
# when they differ, so a hand-written matrix needs nothing but `version` and the
# runner scripts fall back to it.
swift_build_json() {
    local version="$1"
    local toolchain swiftly obj
    toolchain=$(toolchain_for "$version")
    swiftly=$(swiftly_for "$version")

    obj=$(jq -n -c --arg v "$version" '{version: $v}')
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
        --argjson security_opts "$linux_docker_security_opts" \
        '.swift_build.container = ({image: $image}
            + (if $dockerfile == "" then {} else {dockerfile: $dockerfile} end)
            + (if ($capabilities | length) == 0 then {} else {capabilities: $capabilities} end)
            + (if ($security_opts | length) == 0 then {} else {security_opts: $security_opts} end))'
}

# Container image for a version label. Takes the label and resolves it, so
# callers do not have to.
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
          else ($o.arguments // "") end' 2>/dev/null || true
}

version_override_command() {
    local version="$1" overrides_json="$2"
    echo "$overrides_json" | jq -r --arg v "$version" '
        .[$v] as $o
        | if ($o | type) == "object" then ($o.command // "") else "" end' 2>/dev/null || true
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

# Build command_arguments as a JSON array from base flags + per-version overrides
build_command_arguments_json() {
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

    if [[ -z "$args" ]]; then
        echo "[]"
        return
    fi

    # Split on whitespace into a JSON array
    local json_array="[]"
    for arg in $args; do
        json_array=$(echo "$json_array" | jq -c --arg a "$arg" '. + [$a]')
    done
    echo "$json_array"
}

# Validate that all keys in an overrides JSON exist in the given version list.
# Warns on unmatched keys with the valid options.
validate_override_keys() {
    local overrides_json="$1" versions_json="$2" label="$3"

    if [[ "$overrides_json" == "{}" || -z "$overrides_json" ]]; then
        return
    fi

    local keys
    keys=$(echo "$overrides_json" | jq -r 'keys[]' 2>/dev/null || true)
    local valid_versions
    valid_versions=$(echo "$versions_json" | jq -r '.[]' 2>/dev/null || true)

    for key in $keys; do
        if ! echo "$valid_versions" | grep -qxF "$key"; then
            log "WARNING: $label override key '$key' does not match any version in the matrix. Valid keys: $(echo "$valid_versions" | tr '\n' ' ')"
        fi
    done
}

# Append a new entry to the matrix JSON
# Usage: matrix=$(add_entry "$matrix" --arg ... --argjson ...)
# We use a simpler approach: build each entry as a standalone JSON object and append.
add_entry() {
    local current_matrix="$1"
    local entry_json="$2"
    echo "$current_matrix" | jq -c --argjson entry "$entry_json" '.config += [$entry]'
}

# Build xcode_targets JSON array from the enable flags
build_xcode_targets() {
    local scheme="$1"
    local targets="[]"

    if [[ -z "$scheme" ]]; then
        echo "[]"
        return
    fi

    add_target() {
        local plat="$1" build_dest="$2" test_dest="$3" do_build="$4" do_test="$5"
        if [[ "$do_build" == "true" || "$do_test" == "true" ]]; then
            targets=$(echo "$targets" | jq -c \
                --arg platform "$plat" \
                --arg scheme "$scheme" \
                --arg build_destination "$build_dest" \
                --arg test_destination "$test_dest" \
                --argjson build "$do_build" \
                --argjson test "$do_test" \
                '. + [{platform: $platform, scheme: $scheme, build_destination: $build_destination, test_destination: $test_destination, build: $build, test: $test}]')
        fi
    }

    add_target "macOS"    "generic/platform=macos,variant=macos"        "name=My Mac,variant=macos"         "$enable_macos_xcode_build"    "$enable_macos_xcode_test"
    add_target "Catalyst" "generic/platform=macos,variant=Mac Catalyst" "name=My Mac,variant=Mac Catalyst"  "$enable_catalyst_xcode_build" "$enable_catalyst_xcode_test"
    add_target "iOS"      "generic/platform=ios"      "name=iPhone Air"                        "$enable_ios_xcode_build"      "$enable_ios_xcode_test"
    add_target "watchOS"  "generic/platform=watchos"   "name=Apple Watch Ultra 3 (49mm)"        "$enable_watchos_xcode_build"  "$enable_watchos_xcode_test"
    add_target "tvOS"     "generic/platform=tvos"      "name=Apple TV 4K (3rd generation)"      "$enable_tvos_xcode_build"     "$enable_tvos_xcode_test"
    add_target "visionOS" "generic/platform=visionos"  "name=Apple Vision Pro"                  "$enable_visionos_xcode_build" "$enable_visionos_xcode_test"

    echo "$targets"
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
release_build_versions="${RELEASE_BUILD_SWIFT_VERSIONS:-}"
if [[ -n "$release_build_versions" ]]; then
    release_build_versions=$(to_json "$release_build_versions")
else
    release_build_versions=$(jq -n -c --arg v "$(newest_release_version "$linux_swift_versions")" '[$v]')
fi

cxx_interop_versions="${CXX_INTEROP_SWIFT_VERSIONS:-}"
if [[ -n "$cxx_interop_versions" ]]; then
    cxx_interop_versions=$(to_json "$cxx_interop_versions")
else
    cxx_interop_versions=$(jq -n -c --arg v "$(newest_release_version "$linux_swift_versions")" '[$v]')
fi

# ===========================================================================
# Build the matrix
# ===========================================================================

# Validate override keys against version lists
validate_override_keys "$linux_version_overrides" "$linux_swift_versions" "linux_version_overrides"
validate_override_keys "$windows_version_overrides" "$windows_swift_versions" "windows_version_overrides"
if [[ -n "$macos_swift_versions" ]]; then
    validate_override_keys "$macos_version_overrides" "$macos_swift_versions" "macos_version_overrides"
elif [[ -n "$macos_xcode_versions" ]]; then
    validate_override_keys "$macos_version_overrides" "$macos_xcode_versions" "macos_version_overrides"
fi

matrix='{"config":[]}'

# ---------------------------------------------------------------------------
# Linux entries
# ---------------------------------------------------------------------------
if [[ "$enable_linux" == "true" ]]; then
    while IFS= read -r arch; do
        [[ -n "$arch" ]] || continue
        # Map architecture to GitHub-hosted runner
        local_runner="ubuntu-24.04"
        if [[ "$arch" == "aarch64" ]]; then
            local_runner="ubuntu-24.04-arm"
        fi

        while IFS= read -r os; do
            [[ -n "$os" ]] || continue
            while IFS= read -r version; do
                [[ -n "$version" ]] || continue
                should_include_version "$version" || continue

                swift_build=$(swift_build_json "$version")
                cmd_args=$(build_command_arguments_json "$version" "$linux_version_overrides")
                entry_command=$(command_for_version "$version" "$linux_version_overrides" "$linux_build_command")

                # Include OS/arch in name only when multiple are configured
                name="Linux Swift $version"
                if [[ "$os_count" -gt 1 ]]; then
                    name="$name $os"
                fi
                if [[ "$arch_count" -gt 1 ]]; then
                    name="$name $arch"
                fi

                entry=$(jq -n -c \
                    --arg platform "Linux" \
                    --arg name "$name" \
                    --argjson swift_build "$swift_build" \
                    --arg setup_command "$linux_pre_build_command" \
                    --arg command "$entry_command" \
                    --argjson command_arguments "$cmd_args" \
                    --argjson env "$linux_env_vars" \
                    --arg runner "$local_runner" \
                    '{platform: $platform, name: $name, runner: [$runner], swift_build: $swift_build, setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env}')

                if [[ "$linux_use_docker" == "true" ]]; then
                    entry=$(add_container "$entry" "$version" "$os")
                fi

                matrix=$(add_entry "$matrix" "$entry")
            done < <(echo "$linux_swift_versions" | jq -r '.[]')
        done < <(echo "$linux_os_list" | jq -r '.[]')
    done < <(echo "$linux_host_archs" | jq -r '.[]')
fi

# ---------------------------------------------------------------------------
# macOS entries
# ---------------------------------------------------------------------------
# macOS entries run on self-hosted pools. A fork has no access to them,
# so its jobs would queue until they time out. When macos_repository_owner is set
# and does not match, no macOS entries are generated — which produces no jobs
# rather than jobs that cannot start.
if [[ "$enable_macos" == "true" || "$enable_macos_swiftly" == "true" ]] \
   && [[ -n "$macos_repository_owner" && -n "$github_repository_owner" ]] \
   && [[ "$macos_repository_owner" != "$github_repository_owner" ]]; then
    log "Skipping macOS entries: this repository's owner ($github_repository_owner) is not $macos_repository_owner"
    enable_macos="false"
    enable_macos_swiftly="false"
fi

if [[ "$enable_macos" == "true" ]]; then
    xcode_targets=$(build_xcode_targets "$xcode_scheme")
    macos_os_count=$(echo "$macos_os_list" | jq 'length')

    while IFS= read -r os; do
        [[ -n "$os" ]] || continue

        # Entries specified by Xcode version
        if [[ -n "$macos_xcode_versions" ]]; then
            while IFS= read -r xcode_version; do
                [[ -n "$xcode_version" ]] || continue

                name="macOS Xcode $xcode_version"
                if [[ "$macos_os_count" -gt 1 ]]; then
                    name="$name $os"
                fi

                cmd_args=$(build_command_arguments_json "$xcode_version" "$macos_version_overrides")
                entry_command=$(command_for_version "$xcode_version" "$macos_version_overrides" "$macos_build_command")

                entry=$(jq -n -c \
                    --arg platform "macOS" \
                    --arg name "$name" \
                    --arg xcode_version "$xcode_version" \
                    --arg os "$os" \
                    --arg arch "$macos_arch" \
                    --arg setup_command "$macos_pre_build_command" \
                    --arg command "$entry_command" \
                    --argjson command_arguments "$cmd_args" \
                    --argjson env "$macos_env_vars" \
                    --arg pool "$macos_runner_pool" \
                    --argjson xcode_targets "$xcode_targets" \
                    --argjson debug_output "$xcode_debug_output" \
                    '{platform: $platform, name: $name, runner: ["self-hosted", "macos", $os, $arch, $pool], xcode_build: {xcode_version: $xcode_version, targets: $xcode_targets, debug_output: $debug_output}, setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env}')

                matrix=$(add_entry "$matrix" "$entry")
            done < <(echo "$macos_xcode_versions" | jq -r '.[]')
        fi

        # Entries specified by Swift version
        if [[ -n "$macos_swift_versions" ]]; then
            while IFS= read -r swift_ver; do
                [[ -n "$swift_ver" ]] || continue

                name="macOS Swift $swift_ver"
                if [[ "$macos_os_count" -gt 1 ]]; then
                    name="$name $os"
                fi

                cmd_args=$(build_command_arguments_json "$swift_ver" "$macos_version_overrides")
                entry_command=$(command_for_version "$swift_ver" "$macos_version_overrides" "$macos_build_command")

                entry=$(jq -n -c \
                    --arg platform "macOS" \
                    --arg name "$name" \
                    --arg swift_version "$swift_ver" \
                    --arg os "$os" \
                    --arg arch "$macos_arch" \
                    --arg setup_command "$macos_pre_build_command" \
                    --arg command "$entry_command" \
                    --argjson command_arguments "$cmd_args" \
                    --argjson env "$macos_env_vars" \
                    --arg pool "$macos_runner_pool" \
                    --argjson xcode_targets "$xcode_targets" \
                    --argjson debug_output "$xcode_debug_output" \
                    '{platform: $platform, name: $name, runner: ["self-hosted", "macos", $os, $arch, $pool], xcode_build: {swift_version: $swift_version, targets: $xcode_targets, debug_output: $debug_output}, setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env}')

                matrix=$(add_entry "$matrix" "$entry")
            done < <(echo "$macos_swift_versions" | jq -r '.[]')
        fi
    done < <(echo "$macos_os_list" | jq -r '.[]')
fi

# ---------------------------------------------------------------------------
# macOS entries using a swiftly-managed toolchain
# ---------------------------------------------------------------------------
if [[ "$enable_macos_swiftly" == "true" ]]; then
    while IFS= read -r toolchain; do
        [[ -n "$toolchain" ]] || continue

        swiftly_xcode=$(echo "$toolchain" | jq -r '.xcode_version // empty')
        swiftly_version=$(echo "$toolchain" | jq -r '.swift_version // empty')
        swiftly_os=$(echo "$toolchain" | jq -r --arg d "$macos_os" '.os_version // $d')
        swiftly_arch=$(echo "$toolchain" | jq -r --arg d "$macos_arch" '.arch // $d')

        if [[ -z "$swiftly_xcode" || -z "$swiftly_version" ]]; then
            log "WARNING: skipping macos_swiftly_toolchains entry without both xcode_version and swift_version: $toolchain"
            continue
        fi

        # Snapshots take the nightly flags, matching how the version lists treat
        # a "nightly-" prefix elsewhere.
        if [[ "$swiftly_version" == *snapshot* ]]; then
            swiftly_args="$swift_nightly_flags"
        else
            swiftly_args="$swift_flags"
        fi
        swiftly_cmd_args="[]"
        for arg in $swiftly_args; do
            swiftly_cmd_args=$(echo "$swiftly_cmd_args" | jq -c --arg a "$arg" '. + [$a]')
        done

        entry=$(jq -n -c \
            --arg platform "macOS" \
            --arg name "macOS Swiftly $swiftly_version (Xcode $swiftly_xcode)" \
            --arg xcode_version "$swiftly_xcode" \
            --arg swiftly_toolchain "$swiftly_version" \
            --arg os "$swiftly_os" \
            --arg arch "$swiftly_arch" \
            --arg setup_command "$macos_pre_build_command" \
            --arg command "$macos_swiftly_build_command" \
            --argjson command_arguments "$swiftly_cmd_args" \
            --argjson env "$macos_env_vars" \
            --arg pool "$macos_runner_pool" \
            '{platform: $platform, name: $name, runner: ["self-hosted", "macos", $os, $arch, $pool], xcode_build: {xcode_version: $xcode_version, swiftly_toolchain: $swiftly_toolchain}, setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env}')

        matrix=$(add_entry "$matrix" "$entry")
    done < <(echo "$macos_swiftly_toolchains" | jq -c '.[]')
fi

# ---------------------------------------------------------------------------
# Windows entries
# ---------------------------------------------------------------------------
if [[ "$enable_windows" == "true" ]]; then
    while IFS= read -r os_version; do
        [[ -n "$os_version" ]] || continue
        while IFS= read -r version; do
            [[ -n "$version" ]] || continue
            should_include_version "$version" || continue

            swift_build=$(swift_build_json "$version")
            cmd_args=$(build_command_arguments_json "$version" "$windows_version_overrides")
            entry_command=$(command_for_version "$version" "$windows_version_overrides" "$windows_build_command")

            os_count=$(echo "$windows_os_versions" | jq 'length')
            if [[ "$os_count" -gt 1 ]]; then
                name="Windows Swift $version $os_version"
            else
                name="Windows Swift $version"
            fi

            entry=$(jq -n -c \
                --arg platform "Windows" \
                --arg name "$name" \
                --argjson swift_build "$swift_build" \
                --arg setup_command "$windows_pre_build_command" \
                --arg command "$entry_command" \
                --argjson command_arguments "$cmd_args" \
                --argjson env "$windows_env_vars" \
                --arg runner "$os_version" \
                '{platform: $platform, name: $name, runner: [$runner], swift_build: $swift_build, setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env}')

            if [[ "$windows_use_docker" == "true" ]]; then
                windows_toolchain=$(toolchain_for "$version")
                if [[ "$windows_toolchain" == nightly-* ]]; then
                    image="swiftlang/swift:${windows_toolchain}-windowsservercore-ltsc2022"
                else
                    image="swift:${windows_toolchain}-windowsservercore-ltsc2022"
                fi
                entry=$(echo "$entry" | jq -c --arg image "$image" '.swift_build.container = {image: $image}')
            fi

        matrix=$(add_entry "$matrix" "$entry")
        done < <(echo "$windows_swift_versions" | jq -r '.[]')
    done < <(echo "$windows_os_versions" | jq -r '.[]')
fi

# ---------------------------------------------------------------------------
# Static Linux SDK entries
# ---------------------------------------------------------------------------
if [[ "$enable_linux_static_sdk" == "true" ]]; then
    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        should_include_version "$version" || continue

        swift_build=$(swift_build_json "$version")
        entry=$(jq -n -c \
            --arg name "Static Linux SDK Swift $version" \
            --argjson swift_build "$swift_build" \
            --arg setup_command "$linux_static_sdk_pre_build_command" \
            --arg command "$linux_static_sdk_build_command" \
            --argjson env "$linux_env_vars" \
            '{platform: "Linux", name: $name, runner: ["ubuntu-latest"], swift_build: ($swift_build + {sdk: {type: "static-linux"}}), setup_command: $setup_command, command: $command, command_arguments: [], env: $env}')

        matrix=$(add_entry "$matrix" "$entry")
    done < <(echo "$linux_static_sdk_versions" | jq -r '.[]')
fi

# ---------------------------------------------------------------------------
# Wasm SDK entries
# ---------------------------------------------------------------------------
if [[ "$enable_wasm_sdk" == "true" ]]; then
    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        should_include_version "$version" || continue

        swift_build=$(swift_build_json "$version")
        entry=$(jq -n -c \
            --arg name "Wasm SDK Swift $version" \
            --argjson swift_build "$swift_build" \
            --arg setup_command "$wasm_sdk_pre_build_command" \
            --arg command "$wasm_sdk_build_command" \
            --argjson env "$linux_env_vars" \
            '{platform: "Linux", name: $name, runner: ["ubuntu-latest"], swift_build: ($swift_build + {sdk: {type: "wasm"}}), setup_command: $setup_command, command: $command, command_arguments: [], env: $env}')

        matrix=$(add_entry "$matrix" "$entry")
    done < <(echo "$wasm_sdk_versions" | jq -r '.[]')
fi

# ---------------------------------------------------------------------------
# Embedded Wasm SDK entries
# ---------------------------------------------------------------------------
if [[ "$enable_embedded_wasm_sdk" == "true" ]]; then
    while IFS= read -r version; do
        [[ -n "$version" ]] || continue
        should_include_version "$version" || continue

        swift_build=$(swift_build_json "$version")
        entry=$(jq -n -c \
            --arg name "Embedded Wasm SDK Swift $version" \
            --argjson swift_build "$swift_build" \
            --arg setup_command "$wasm_sdk_pre_build_command" \
            --arg command "$embedded_wasm_sdk_build_command" \
            --argjson env "$linux_env_vars" \
            '{platform: "Linux", name: $name, runner: ["ubuntu-latest"], swift_build: ($swift_build + {sdk: {type: "wasm-embedded"}}), setup_command: $setup_command, command: $command, command_arguments: [], env: $env}')

        matrix=$(add_entry "$matrix" "$entry")
    done < <(echo "$embedded_wasm_sdk_versions" | jq -r '.[]')
fi

# ---------------------------------------------------------------------------
# Android SDK entries
# ---------------------------------------------------------------------------
if [[ "$enable_android_sdk" == "true" ]]; then
    while IFS= read -r ndk_version; do
        [[ -n "$ndk_version" ]] || continue
        while IFS= read -r version; do
            [[ -n "$version" ]] || continue
            should_include_version "$version" || continue

            swift_build=$(swift_build_json "$version")
            # The emulator script stages what the SDK build produced, so the
            # build itself has to be asked for test binaries.
            if [[ "$enable_android_sdk_checks" == "true" ]]; then
                cmd_args='["--build-tests"]'
            else
                cmd_args="[]"
            fi

            entry=$(jq -n -c \
                --arg name "Android SDK Swift $version NDK $ndk_version" \
                --argjson swift_build "$swift_build" \
                --arg ndk_version "$ndk_version" \
                --argjson triples "$android_triples" \
                --arg setup_command "$android_sdk_pre_build_command" \
                --arg command "$android_sdk_build_command" \
                --argjson command_arguments "$cmd_args" \
                --argjson env "$linux_env_vars" \
                --argjson emulator_enabled "$([ "$enable_android_sdk_checks" == "true" ] && echo true || echo false)" \
                '{platform: "Linux", name: $name, runner: ["ubuntu-latest"], swift_build: ($swift_build + {sdk: {type: "android", ndk_version: $ndk_version, triples: $triples}}), setup_command: $setup_command, command: $command, command_arguments: $command_arguments, env: $env, android_emulator: $emulator_enabled}')

            matrix=$(add_entry "$matrix" "$entry")
        done < <(echo "$android_sdk_versions" | jq -r '.[]')
    done < <(echo "$android_ndk_versions" | jq -r '.[]')
fi

# ===========================================================================
# Release build entries
# ===========================================================================
if [[ "$enable_release_build" == "true" ]]; then
    while IFS= read -r os; do
        [[ -n "$os" ]] || continue
        while IFS= read -r version; do
            [[ -n "$version" ]] || continue
            should_include_version "$version" || continue

            swift_build=$(swift_build_json "$version")
            name="Release build Swift $version"
            if [[ "$os_count" -gt 1 ]]; then
                name="$name $os"
            fi

            entry=$(jq -n -c \
                --arg name "$name" \
                --argjson swift_build "$swift_build" \
                --arg setup_command "$linux_pre_build_command" \
                --argjson env "$linux_env_vars" \
                '{platform: "Linux", name: $name, runner: ["ubuntu-latest"], swift_build: $swift_build, setup_command: $setup_command, command: "swift build -c release", command_arguments: [], env: $env}')

            if [[ "$linux_use_docker" == "true" ]]; then
                entry=$(add_container "$entry" "$version" "$os")
            fi

            matrix=$(add_entry "$matrix" "$entry")
        done < <(echo "$release_build_versions" | jq -r '.[]')
    done < <(echo "$linux_os_list" | jq -r '.[]')
fi

# ===========================================================================
# Cxx interop entries
# ===========================================================================
if [[ "$enable_cxx_interop" == "true" ]]; then
    while IFS= read -r os; do
        [[ -n "$os" ]] || continue
        while IFS= read -r version; do
            [[ -n "$version" ]] || continue
            should_include_version "$version" || continue

            swift_build=$(swift_build_json "$version")
            name="Cxx interop Swift $version"
            if [[ "$os_count" -gt 1 ]]; then
                name="$name $os"
            fi

            entry=$(jq -n -c \
                --arg name "$name" \
                --argjson swift_build "$swift_build" \
                --arg setup_command "$linux_pre_build_command" \
                --argjson env "$linux_env_vars" \
                '{platform: "Linux", name: $name, runner: ["ubuntu-latest"], swift_build: $swift_build, setup_command: $setup_command, command: "${SCRIPTS_ROOT}/check-cxx-interop.sh", command_arguments: [], env: $env}')

            if [[ "$linux_use_docker" == "true" ]]; then
                entry=$(add_container "$entry" "$version" "$os")
            fi

            matrix=$(add_entry "$matrix" "$entry")
        done < <(echo "$cxx_interop_versions" | jq -r '.[]')
    done < <(echo "$linux_os_list" | jq -r '.[]')
fi

# ===========================================================================
# FreeBSD entries
# ===========================================================================
if [[ "$enable_freebsd" == "true" ]]; then
    while IFS= read -r os_ver; do
        [[ -n "$os_ver" ]] || continue
        while IFS= read -r version; do
            [[ -n "$version" ]] || continue

            entry=$(jq -n -c \
                --arg platform "FreeBSD" \
                --arg name "FreeBSD $version - $os_ver - x86_64" \
                --arg os_version "$os_ver" \
                --arg swift_version "$version" \
                --arg swift_url "https://download.swift.org/tmp-ci-nightly/development/freebsd-14_ci_latest.tar.gz" \
                --arg build_flags "$swift_nightly_flags" \
                --arg env_vars "$freebsd_env_vars" \
                --arg setup_command "$freebsd_pre_build_command" \
                --arg command "$freebsd_build_command" \
                '{platform: $platform, name: $name, runner: ["ubuntu-24.04"], freebsd: {os_version: $os_version, swift_version: $swift_version, swift_url: $swift_url, build_flags: $build_flags, env_vars: $env_vars}, setup_command: $setup_command, command: $command, command_arguments: [], env: {}}')

            matrix=$(add_entry "$matrix" "$entry")
        done < <(echo "$freebsd_swift_versions" | jq -r '.[]')
    done < <(echo "$freebsd_os_versions" | jq -r '.[]')
fi

# ===========================================================================
# Output as YAML
# ===========================================================================
if [[ "$matrix_mode" == "toolchains" ]]; then
    # Drop what a caller supplies instead. env is kept, since it describes the
    # environment a toolchain needs rather than the work being run in it.
    matrix=$(echo "$matrix" | jq -c '.config |= map(del(.command, .setup_command, .command_arguments))')
fi

entry_count=$(echo "$matrix" | jq '.config | length')

if [[ "$entry_count" -eq 0 ]]; then
    log "Warning: no matrix entries generated (all platforms disabled or filtered)"
else
    log "Generated $entry_count matrix entries"
fi

if [[ "$matrix_format" == "json" ]]; then
    echo "$matrix" | jq .
else
    echo "$matrix" | yq -P
fi
