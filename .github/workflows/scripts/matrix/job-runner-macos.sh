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

# This script runs a command on macOS with a specific Xcode version, then
# optionally runs xcodebuild for additional platform targets (iOS, watchOS, etc).
#
# Arguments:
#   $1: Xcode version (e.g. "26.2", can be empty if swift_version is set)
#   $2: Swift version (e.g. "6.2", can be empty if xcode_version is set)
#   $3: Setup command (can be empty)
#   $4: Main command to run
#   $5: JSON array or string of command arguments
#   $6: JSON string of environment variables (can be empty)
#   $7: needs_token (true/false, optional)
#
# Environment variables:
#   XCODE_TARGETS_JSON  - JSON array of xcodebuild targets to run after the main command.
#                         Each entry: {"platform": "iOS", "scheme": "...",
#                                      "build_destination": "generic/platform=ios",
#                                      "test_destination": "name=iPhone Air",
#                                      "build": true, "test": false}
#   SWIFTLY_TOOLCHAIN   - A swiftly toolchain selector (e.g. "main-snapshot"). When set,
#                         that toolchain is installed and selected under the chosen Xcode,
#                         so the command can run through `swiftly run`.
#   XCODE_DEBUG_OUTPUT  - "true" to drop -quiet from the xcodebuild target invocations.
#   XCODE_APPLICATIONS_DIRECTORY
#                       - Where the Xcode apps live. Defaults to /Applications; the
#                         tests point it at a directory holding a symlink so the
#                         script can be driven without a runner's Xcode layout.

xcode_version="${1:-}"
swift_version="${2:-}"
setup_command="${3:-}"
command="$4"
command_arguments_json="${5:-}"
env_json="${6:-}"
needs_token="${7:-false}"
xcode_targets_json="${XCODE_TARGETS_JSON:-}"
swiftly_toolchain="${SWIFTLY_TOOLCHAIN:-}"
xcode_debug_output="${XCODE_DEBUG_OUTPUT:-false}"
xcode_applications_directory="${XCODE_APPLICATIONS_DIRECTORY:-/Applications}"

log() { echo "** $*" >&2; }

# Select Xcode.
#
# This sets DEVELOPER_DIR rather than running `xcode-select -s`, which would
# change the selection for every other job sharing the runner. Both upstreams
# use DEVELOPER_DIR for the same reason.
#
# "latest-beta" names whatever beta the runner currently carries, via the
# Xcode-latest.app symlink, so a workflow does not need editing each time a beta
# ships.
if [[ "$xcode_version" == "latest-beta" ]]; then
  xcode_app="${xcode_applications_directory}/Xcode-latest.app"
elif [[ -n "$xcode_version" ]]; then
  xcode_app="${xcode_applications_directory}/Xcode_${xcode_version}.app"
elif [[ -n "$swift_version" ]]; then
  xcode_app="${xcode_applications_directory}/Xcode_swift_${swift_version}.app"
else
  log "ERROR: neither xcode_version nor swift_version provided"
  exit 1
fi

if [[ ! -d "$xcode_app" ]]; then
  log "ERROR: $xcode_app not found on this runner"
  exit 1
fi

export DEVELOPER_DIR="${xcode_app}/Contents/Developer"
log "Using DEVELOPER_DIR=$DEVELOPER_DIR"

# Provide token if needed
if [[ "$needs_token" == "true" && -n "${GITHUB_TOKEN:-}" ]]; then
  export GITHUB_TOKEN="$GITHUB_TOKEN"
fi

# Export environment variables
if [[ -n "$env_json" && "$env_json" != '{}' && "$env_json" != 'null' ]]; then
  while IFS="=" read -r key value; do
    if [[ -n "$key" && -n "$value" ]]; then
      export "$key=$value"
    fi
  done < <(echo "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
fi

# Install a swiftly-managed toolchain on top of the selected Xcode. Used to test
# nightly snapshots on macOS, where there is no Xcode for them to come from.
if [[ -n "$swiftly_toolchain" ]]; then
  swiftly_env="$HOME/.swiftly/env.sh"
  if [[ ! -f "$swiftly_env" ]]; then
    log "ERROR: swiftly is not installed on this runner ($swiftly_env not found)"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$swiftly_env"
  log "Installing swiftly toolchain: $swiftly_toolchain"
  swiftly install "$swiftly_toolchain" --use
  echo "Swiftly Swift version:"
  swiftly run swift --version
else
  echo "Swift version:"
  xcrun swift --version

  echo "Clang version:"
  xcrun clang --version
fi

# Convert command_arguments
command_arguments=""
if [[ -n "$command_arguments_json" && "$command_arguments_json" != "null" && "$command_arguments_json" != '[]' ]]; then
  if [[ "$command_arguments_json" =~ ^\[.*\]$ ]]; then
    command_arguments=$(echo "$command_arguments_json" | jq -r 'join(" ")')
  else
    command_arguments="$command_arguments_json"
  fi
fi

# The setup command and the command run in one shell, so a `cd` in setup carries
# into the command. That is how a caller reaches a package below the repository
# root, and Linux and Windows both behave this way.
full_command="$command $command_arguments"
if [[ -n "$setup_command" ]]; then
  log "Running setup command"
  log "Executing command: $full_command"
  bash -ec "$setup_command"$'\n'"$full_command"
else
  log "Executing command: $full_command"
  bash -ec "$full_command"
fi

# ---------------------------------------------------------------------------
# Xcode platform targets (build + optional test for iOS, watchOS, etc.)
# ---------------------------------------------------------------------------
if [[ -n "$xcode_targets_json" && "$xcode_targets_json" != "null" && "$xcode_targets_json" != '[]' ]]; then
  target_count=$(echo "$xcode_targets_json" | jq 'length')
  log "Running $target_count xcodebuild target(s)"

  # xcodebuild is quiet unless asked otherwise; a failing target is often
  # impossible to diagnose from the summary alone.
  quiet_arg=("-quiet")
  if [[ "$xcode_debug_output" == "true" ]]; then
    quiet_arg=()
  fi

  for i in $(seq 0 $((target_count - 1))); do
    target=$(echo "$xcode_targets_json" | jq -c ".[$i]")
    platform=$(echo "$target" | jq -r '.platform')
    scheme=$(echo "$target" | jq -r '.scheme')
    build_dest=$(echo "$target" | jq -r '.build_destination // empty')
    test_dest=$(echo "$target" | jq -r '.test_destination // empty')
    do_build=$(echo "$target" | jq -r '.build // true')
    do_test=$(echo "$target" | jq -r '.test // false')

    if [[ "$do_build" == "true" && -n "$build_dest" ]]; then
      # build-for-testing rather than build, so that test code is type-checked
      # too. Plain `build` compiles only the scheme's build targets, which leaves
      # a package's tests unchecked on every platform that is not being run on.
      # It succeeds on packages with no test targets.
      log "$platform build: xcodebuild -scheme $scheme -destination $build_dest build-for-testing"
      /usr/bin/xcodebuild ${quiet_arg[@]+"${quiet_arg[@]}"} -scheme "$scheme" -destination "$build_dest" build-for-testing
    fi

    if [[ "$do_test" == "true" && -n "$test_dest" ]]; then
      log "$platform test: xcodebuild -scheme $scheme -destination $test_dest test"
      /usr/bin/xcrun simctl shutdown all
      /usr/bin/xcodebuild ${quiet_arg[@]+"${quiet_arg[@]}"} -scheme "$scheme" -destination "$test_dest" test
    fi
  done
fi
