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

# This script runs commands on a Linux host, either natively (via swiftly)
# or inside a Docker container when CONTAINER_JSON is set.
#
# Arguments:
#   $1: Swift version label (e.g., "6.2", "nightly-release")
#   $2: Setup command (can be empty)
#   $3: Main command to run
#   $4: JSON array or string of command arguments
#   $5: JSON string of environment variables (can be empty)
#   $6: needs_token (true/false, optional)
#   $7: SDK JSON configuration (optional)
#
# Environment variables:
#   CONTAINER_JSON    - JSON with optional Docker container config (image, dockerfile, capabilities)
#   SCRIPTS_ROOT      - Path to the github-workflows scripts directory
#   MATRIX_TOOLCHAIN  - The concrete toolchain identifier for the version label
#                       (e.g. "nightly-6.4.x" for "nightly-release"). Defaults to
#                       the label, which is correct for plain release versions.
#   MATRIX_SWIFTLY    - The swiftly selector for the version label (e.g.
#                       "6.4-snapshot"). Defaults to the label.
#   CROSS_PR_TESTING  - "true" to check out PRs linked from this PR's description,
#                       after the toolchain is installed.
#   CROSS_PR_REPO     - The repository the pull request is against.
#   CROSS_PR_NUMBER   - The pull request number.

swift_version="$1"
setup_command="${2:-}"
command="$3"
command_arguments_json="${4:-}"
env_json="${5:-}"
needs_token="${6:-false}"
sdk_json="${7:-}"

# A hand-written matrix may supply only `version`, so both resolved forms fall
# back to it rather than being re-derived here.
matrix_toolchain="${MATRIX_TOOLCHAIN:-$swift_version}"
matrix_swiftly="${MATRIX_SWIFTLY:-$swift_version}"

log() { echo "** $*" >&2; }

command -v jq >/dev/null || { echo "** ERROR: jq not found on PATH" >&2; exit 1; }

container_json="${CONTAINER_JSON:-null}"
container_image=""
container_dockerfile=""
container_capabilities="[]"
container_security_opts="[]"

if [[ -n "$container_json" && "$container_json" != "null" && "$container_json" != '{}' ]]; then
    container_image=$(echo "$container_json" | jq -r '.image // empty')
    container_dockerfile=$(echo "$container_json" | jq -r '.dockerfile // empty')
    container_capabilities=$(echo "$container_json" | jq -c '.capabilities // []')
    container_security_opts=$(echo "$container_json" | jq -c '.security_opts // []')
fi

# ---------------------------------------------------------------------------
# Convert command_arguments JSON to a flat string
# ---------------------------------------------------------------------------
parse_command_arguments() {
    if [[ -n "$command_arguments_json" && "$command_arguments_json" != "null" && "$command_arguments_json" != '[]' ]]; then
        if [[ "$command_arguments_json" =~ ^\[.*\]$ ]]; then
            echo "$command_arguments_json" | jq -r 'join(" ")'
        else
            echo "$command_arguments_json"
        fi
    fi
}

command_arguments=$(parse_command_arguments)

# ---------------------------------------------------------------------------
# Docker execution path
# ---------------------------------------------------------------------------
if [[ -n "$container_image" ]]; then
    log "Running in Docker container: $container_image"

    actual_image="$container_image"

    # Build from Dockerfile if specified
    if [[ -n "$container_dockerfile" ]]; then
        local_tag="local-ci-image:$(echo "$swift_version" | tr ':/' '-')"
        docker buildx build \
            --build-arg SWIFT_IMAGE="$container_image" \
            -f "$container_dockerfile" \
            -t "$local_tag" \
            .
        actual_image="$local_tag"
    else
        docker pull "$actual_image"
    fi

    workspace="/$(basename "${GITHUB_WORKSPACE:-.}")"

    docker_args=(
        "run"
        "-v" "${GITHUB_WORKSPACE:-.}:$workspace"
        "-w" "$workspace"
        "-e" "CI=${CI:-}"
        "-e" "GITHUB_ACTIONS=${GITHUB_ACTIONS:-}"
        "-e" "SWIFT_VERSION=$swift_version"
        "-e" "workspace=$workspace"
    )

    # The scripts directory lives under GITHUB_WORKSPACE, so it is already
    # inside the mount — but at a different absolute path. Translate it so
    # commands that reference ${SCRIPTS_ROOT} resolve inside the container.
    if [[ -n "${SCRIPTS_ROOT:-}" && -n "${GITHUB_WORKSPACE:-}" ]]; then
        docker_args+=("-e" "SCRIPTS_ROOT=${SCRIPTS_ROOT/#$GITHUB_WORKSPACE/$workspace}")
    fi

    # Docker capabilities (e.g. CAP_BPF)
    if [[ "$container_capabilities" != '[]' ]]; then
        while IFS= read -r cap; do
            docker_args+=("--cap-add=$cap")
        done < <(echo "$container_capabilities" | jq -r '.[]')
    fi

    # Docker security options (e.g. apparmor=unconfined)
    if [[ "$container_security_opts" != '[]' ]]; then
        while IFS= read -r opt; do
            docker_args+=("--security-opt=$opt")
        done < <(echo "$container_security_opts" | jq -r '.[]')
    fi

    # Environment variables
    if [[ -n "$env_json" && "$env_json" != '{}' && "$env_json" != 'null' ]]; then
        while IFS="=" read -r key value; do
            if [[ -n "$key" && -n "$value" ]]; then
                docker_args+=("-e" "$key=$value")
            fi
        done < <(echo "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi

    # Pass GITHUB_TOKEN if needed
    if [[ "$needs_token" == "true" && -n "${GITHUB_TOKEN:-}" ]]; then
        docker_args+=("-e" "GITHUB_TOKEN=$GITHUB_TOKEN")
    fi

    docker_args+=("$actual_image")

    # Build the shell command to run inside Docker
    if [[ -n "$setup_command" ]]; then
        docker_args+=("bash" "-ec" "$setup_command"$'\n'"$command $command_arguments")
    else
        docker_args+=("bash" "-ec" "$command $command_arguments")
    fi

    log "Executing: docker ${docker_args[*]}"
    docker "${docker_args[@]}"
    exit $?
fi

# ---------------------------------------------------------------------------
# Native execution path (swiftly)
# ---------------------------------------------------------------------------

refresh_package_cache() {
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -y -q
    elif command -v dnf &> /dev/null; then
        sudo dnf makecache -q
    elif command -v yum &> /dev/null; then
        sudo yum makecache -q
    fi
}

install_swiftly() {
    if command -v swiftly &> /dev/null; then
        log "Swiftly is already installed"
        return 0
    fi

    log "Installing swiftly..."
    curl -fsSL -O "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
    tar zxf "swiftly-$(uname -m).tar.gz"
    ./swiftly init --quiet-shell-followup --skip-install --assume-yes
    # shellcheck source=/dev/null
    source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
    hash -r
    rm -f "swiftly-$(uname -m).tar.gz"
    rm -f swiftly
    log "Swiftly installed successfully"
}

install_swift() {
    local swiftly_version="$1"

    log "Installing Swift $swiftly_version using swiftly..."
    local post_install_file="/tmp/swiftly-post-install.sh"
    swiftly install "$swiftly_version" --use --post-install-file="$post_install_file"
    if [[ -f "$post_install_file" && -s "$post_install_file" ]]; then
        log "Running post-install commands..."
        cat "$post_install_file"
        sudo bash "$post_install_file"
        rm -f "$post_install_file"
    fi
    log "Swift installed successfully"
    swift --version
}

# Skip Swift installation when an SDK is configured (SDK script handles its own toolchain)
skip_swift_install="${SKIP_SWIFT_INSTALL:-false}"
if [[ -n "$sdk_json" && "$sdk_json" != "null" && "$sdk_json" != '{}' ]]; then
    skip_swift_install="true"
fi

# Refresh package cache so swiftly's post-install apt-get doesn't hit stale mirrors
refresh_package_cache

if [[ "$skip_swift_install" != "true" ]]; then
    install_swiftly
    # shellcheck source=/dev/null
    source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
    hash -r
    install_swift "$matrix_swiftly"
else
    log "Skipping Swift installation"
    install_swiftly
    # shellcheck source=/dev/null
    source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
    hash -r
fi

# Check out linked PRs, now that a toolchain exists to compile the script with.
# Doing this before the toolchain was installed only worked because the runner
# image happens to ship a Swift, and would silently use the wrong one.
if [[ "${CROSS_PR_TESTING:-false}" == "true" && -n "${CROSS_PR_REPO:-}" ]]; then
    cross_pr_script="${SCRIPTS_ROOT:-./.github/workflows/scripts}/cross-pr-checkout.swift"
    log "Checking out linked PRs"
    cp "$cross_pr_script" /tmp/cross-pr-checkout.swift
    swift /tmp/cross-pr-checkout.swift "$CROSS_PR_REPO" "${CROSS_PR_NUMBER:-}"
fi

# Handle environment variables
if [[ -n "$env_json" && "$env_json" != '{}' && "$env_json" != 'null' ]]; then
    while IFS="=" read -r key value; do
        if [[ -n "$key" && -n "$value" ]]; then
            export "$key=$value"
        fi
    done < <(echo "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
fi

# Handle SDK builds — the SDK script handles toolchain matching, SDK
# installation, and building in a single invocation to ensure the
# toolchain and SDK are from the same build.
if [[ -n "$sdk_json" && "$sdk_json" != "null" && "$sdk_json" != '{}' ]]; then
    sdk_type=$(echo "$sdk_json" | jq -r '.type // empty')

    if [[ -n "$sdk_type" ]]; then
        log "Will build with SDK: $sdk_type"

        sdk_script="${SCRIPTS_ROOT:-./.github/workflows/scripts}/install-and-build-with-sdk.sh"

        sdk_flags="$command_arguments"
        sdk_build_cmd="$command"

        # The SDK script builds in the current directory, so the setup command
        # has to run first — it is how a caller enters a package that is not at
        # the repository root.
        if [[ -n "$setup_command" ]]; then
            log "Running setup command"
            eval "$setup_command"
        fi

        case "$sdk_type" in
            static-linux)
                "$sdk_script" --static --flags="$sdk_flags" --build-command="$sdk_build_cmd" "$matrix_toolchain"
                ;;
            wasm)
                "$sdk_script" --wasm --flags="$sdk_flags" --build-command="$sdk_build_cmd" "$matrix_toolchain"
                ;;
            wasm-embedded)
                "$sdk_script" --embedded-wasm --flags="$sdk_flags" "$matrix_toolchain"
                ;;
            android)
                ndk_version=$(echo "$sdk_json" | jq -r '.ndk_version // "r27d"')
                triples=$(echo "$sdk_json" | jq -r '.triples[]?' | sed 's/^/--android-sdk-triple=/' | tr '\n' ' ')
                eval "$sdk_script --android --android-ndk-version=$ndk_version $triples --flags=\"$sdk_flags\" --build-command=\"$sdk_build_cmd\" \"\$matrix_toolchain\""
                ;;
            *)
                log "Error: Unknown SDK type: $sdk_type"
                exit 1
                ;;
        esac
        exit $?
    fi
fi

# Build and execute full command (non-SDK path — SDK builds exit above)
if [[ -n "$setup_command" ]]; then
    log "Running setup command"
    eval "$setup_command"
fi

full_command="$command $command_arguments"
log "Executing command: $full_command"
eval "$full_command"
