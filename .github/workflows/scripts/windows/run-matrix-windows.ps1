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
# This script runs Swift commands natively on Windows with custom environment variables
# Parameters:
#   -SwiftVersion: Swift version to use (e.g., "6.2", "nightly-main")
#   -SetupCommand: Setup command (can be empty)
#   -Command: Main command to run
#   -CommandArguments: JSON array or string of command arguments
#   -EnvJson: JSON string of environment variables (can be empty)
#   -NeedsToken: Boolean ("true"/"false") - if "true", passes GITHUB_TOKEN to environment

param(
    [Parameter(Mandatory=$true)]
    [string]$SwiftVersion,

    [Parameter(Mandatory=$false)]
    [string]$SetupCommand = "",

    [Parameter(Mandatory=$true)]
    [string]$Command,

    [Parameter(Mandatory=$false)]
    [string]$CommandArguments = "",

    [Parameter(Mandatory=$false)]
    [string]$EnvJson = "",

    [Parameter(Mandatory=$false)]
    [string]$NeedsToken = "false"
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Docker execution path
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($env:CONTAINER_IMAGE)) {
    Write-Host "Running in Docker container: $env:CONTAINER_IMAGE"

    # Wait for the Docker daemon, starting the service first — polling alone
    # hangs for the full timeout when the service is simply not running.
    $maxAttempts = 30
    $attempt = 0
    do {
        $attempt++
        if ((Get-Service docker).Status -ne "Running") {
            Start-Service docker
        }
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        if ($attempt -ge $maxAttempts) {
            Write-Error "Docker daemon did not become ready after $maxAttempts attempts"
            exit 1
        }
        Start-Sleep -Seconds 6
    } while ($true)

    docker pull $env:CONTAINER_IMAGE
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to pull Docker image: $env:CONTAINER_IMAGE"
        exit 1
    }

    # Build command to run inside container
    $innerCommand = ""
    if (-not [string]::IsNullOrEmpty($SetupCommand)) {
        $innerCommand = "$SetupCommand & "
    }
    $innerCommand += "swift --version & $Command"

    # Convert command arguments
    if (-not [string]::IsNullOrEmpty($CommandArguments) -and $CommandArguments -ne 'null' -and $CommandArguments -ne '[]') {
        if ($CommandArguments.Trim().StartsWith('[')) {
            $args_array = $CommandArguments | ConvertFrom-Json
            $innerCommand += " " + ($args_array -join ' ')
        } else {
            $innerCommand += " $CommandArguments"
        }
    }

    $workspace = "C:\source"
    $docker_args = @(
        "run",
        "-v", "$env:GITHUB_WORKSPACE`:$workspace",
        "-w", $workspace,
        "-e", "CI=$env:CI",
        "-e", "GITHUB_ACTIONS=$env:GITHUB_ACTIONS",
        "-e", "SWIFT_VERSION=$SwiftVersion"
    )

    # Pass environment variables
    if (-not [string]::IsNullOrEmpty($EnvJson) -and $EnvJson -ne '{}' -and $EnvJson -ne 'null') {
        $env_obj = $EnvJson | ConvertFrom-Json
        if ($null -ne $env_obj) {
            $env_obj.PSObject.Properties | ForEach-Object {
                $docker_args += "-e"
                $docker_args += "$($_.Name)=$($_.Value)"
            }
        }
    }

    if ($NeedsToken -eq "true" -and -not [string]::IsNullOrEmpty($env:GITHUB_TOKEN)) {
        $docker_args += "-e"
        $docker_args += "GITHUB_TOKEN=$env:GITHUB_TOKEN"
    }

    $docker_args += @($env:CONTAINER_IMAGE, "cmd", "/s", "/c", $innerCommand)

    Write-Host "Executing: docker $($docker_args -join ' ')"
    & docker @docker_args
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Native execution path
# ---------------------------------------------------------------------------

# Determine script root (where the helper scripts are located)
if ($env:GITHUB_WORKSPACE) {
    if (Test-Path "$env:GITHUB_WORKSPACE\.github\workflows\scripts\windows") {
        $ScriptRoot = "$env:GITHUB_WORKSPACE\.github\workflows\scripts\windows"
    } elseif (Test-Path "$env:GITHUB_WORKSPACE\github-workflows\.github\workflows\scripts\windows") {
        $ScriptRoot = "$env:GITHUB_WORKSPACE\github-workflows\.github\workflows\scripts\windows"
    } else {
        Write-Error "Cannot find scripts directory"
        exit 1
    }
} else {
    $ScriptRoot = $PSScriptRoot
}

Write-Host "Script root: $ScriptRoot"

# Import helper functions from install-swift.ps1
. "$ScriptRoot\swift\install-swift.ps1"

# Verify Python is available (installed by workflow)
Write-Host "Verifying Python installation..."
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Error "Python is not installed. The workflow should install Python before calling this script."
    exit 1
}
python --version

# Install Visual Studio Build Tools
Write-Host "Installing Visual Studio Build Tools..."
if (-not (Test-Path "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools")) {
    . "$ScriptRoot\install-vsb.ps1"
} else {
    Write-Host "Visual Studio Build Tools already installed, skipping..."
}

# Install Swift. The install scripts are named after the concrete toolchain
# identifier rather than the version label, so "nightly-release" resolves to
# install-swift-nightly-6.4.x.ps1.
$Toolchain = if ([string]::IsNullOrEmpty($env:MATRIX_TOOLCHAIN)) { $SwiftVersion } else { $env:MATRIX_TOOLCHAIN }
Write-Host "Installing Swift $Toolchain..."
$swiftInstallScript = "$ScriptRoot\swift\install-swift-$Toolchain.ps1"
if (Test-Path $swiftInstallScript) {
    . $swiftInstallScript
} else {
    Write-Error "No installation script found for Swift $Toolchain at $swiftInstallScript"
    exit 1
}

# Verify Swift installation
Write-Host "Verifying Swift installation..."
swift --version
if ($LASTEXITCODE -ne 0) {
    Write-Error "Swift installation verification failed"
    exit 1
}

Write-Host "Verifying Clang installation..."
clang --version
if ($LASTEXITCODE -ne 0) {
    Write-Error "Clang installation verification failed"
    exit 1
}

# Cross-PR checkout (if enabled)
if ($env:CROSS_PR_TESTING -eq "true" -and -not [string]::IsNullOrEmpty($env:CROSS_PR_REPO)) {
    Write-Host "Checking out linked PRs..."
    $crossPrScript = "$env:SCRIPTS_ROOT\cross-pr-checkout.swift"
    if (Test-Path $crossPrScript) {
        & swiftc -sdk $env:SDKROOT $crossPrScript -o $env:TEMP\cross-pr-checkout.exe
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Warning: Failed to compile cross-pr-checkout.swift, skipping"
        } else {
            & $env:TEMP\cross-pr-checkout.exe $env:CROSS_PR_REPO $env:CROSS_PR_NUMBER
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Warning: Cross-PR checkout failed, continuing without linked PRs"
            }
        }
    } else {
        Write-Host "Warning: cross-pr-checkout.swift not found at $crossPrScript, skipping"
    }
}

# Set environment variables from JSON
if (-not [string]::IsNullOrEmpty($EnvJson) -and $EnvJson -ne '{}' -and $EnvJson -ne 'null') {
    Write-Host "Setting custom environment variables..."
    $env_obj = $EnvJson | ConvertFrom-Json
    if ($null -ne $env_obj) {
        $env_obj.PSObject.Properties | ForEach-Object {
            if (-not [string]::IsNullOrEmpty($_.Name) -and -not [string]::IsNullOrEmpty($_.Value)) {
                Write-Host "  $($_.Name)=$($_.Value)"
                Set-Item -Path "env:$($_.Name)" -Value $_.Value
            }
        }
    }
}

# Provide token if needed
if ($NeedsToken -eq "true" -and -not [string]::IsNullOrEmpty($env:GITHUB_TOKEN)) {
    Write-Host "GITHUB_TOKEN is available for use"
    # Token is already in environment, no need to set it again
}

# Convert command_arguments - support both array [], string, and null
$command_args_string = ""
if (-not [string]::IsNullOrEmpty($CommandArguments) -and $CommandArguments -ne 'null' -and $CommandArguments -ne '[]') {
    # Check if it's a JSON array
    if ($CommandArguments.Trim().StartsWith('[')) {
        $args_array = $CommandArguments | ConvertFrom-Json
        $command_args_string = $args_array -join ' '
    } else {
        # If it's a plain string, use as-is
        $command_args_string = $CommandArguments
    }
}

# Build the full command
$fullCommand = $Command
if (-not [string]::IsNullOrEmpty($command_args_string)) {
    $fullCommand = "$Command $command_args_string"
}

# Invoke-Program propagates a child process's exit code. Dot-sourced rather than
# defined here so that it can be tested on its own, and sourced before the setup
# command runs so that both it and the main command can use it.
. "$ScriptRoot\invoke-program.ps1"

# Run setup command if provided
if (-not [string]::IsNullOrEmpty($SetupCommand)) {
    Write-Host "Running setup command: $SetupCommand"
    Invoke-Expression $SetupCommand
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Setup command failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

# Run the main command
Write-Host "Running command: $fullCommand"
Invoke-Expression $fullCommand
if ($LASTEXITCODE -ne 0) {
    Write-Error "Command failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "Command completed successfully"
