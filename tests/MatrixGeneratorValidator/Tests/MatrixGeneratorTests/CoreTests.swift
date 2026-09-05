//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import MatrixTestSupport
import Testing

// There is one test per axis of customization, asserting only what that axis
// controls, so a failure names the feature that broke rather than showing a whole
// matrix and leaving the reader to work out which part matters.

@Suite("Platform selection")
struct PlatformSelectionTests {
  @Test(
    "Each enable flag selects its platform",
    arguments: [
      (["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["6.3"]"#], "Linux"),
      (["ENABLE_WINDOWS": "true", "WINDOWS_SWIFT_VERSIONS": #"["6.3"]"#], "Windows"),
      (["ENABLE_MACOS": "true", "MACOS_SWIFT_VERSIONS": #"["6.3"]"#], "macOS"),
    ]
  )
  func enableFlagSelectsPlatform(environment: [String: String], platform: String) throws {
    let generated = try Generator.run(environment)
    #expect(Set(generated.platforms) == [platform])
  }

  @Test("Every platform disabled generates nothing, without failing")
  func allDisabled() throws {
    let generated = try Generator.run()
    #expect(generated.count == 0)
    #expect(generated.exitCode == 0)
  }

  @Test("Linux and Windows are the defaults")
  func defaults() throws {
    let generated = try Generator.run(includePlatformDefaults: true)
    #expect(Set(generated.platforms) == ["Linux", "Windows"])
  }
}

@Suite("Version lists")
struct VersionListTests {
  @Test("The version list drives one entry each")
  func versionList() throws {
    let generated = try Generator.run(["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["6.2","6.3"]"#])
    #expect(generated.versions == ["6.2", "6.3"])
  }

  @Test("A version list may be written as YAML")
  func yamlVersionList() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": """
      - "6.2"
      - "6.3"
      """,
    ])
    #expect(generated.versions == ["6.2", "6.3"])
  }
}

@Suite("Minimum version detection")
struct MinimumVersionTests {
  @Test("The manifest's tools version filters older versions out")
  func detectedFromManifest() throws {
    let generated = try Generator.run(
      ["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["6.1","6.2","6.3"]"#],
      manifests: ["Package.swift": Generator.manifest(toolsVersion: "6.2")]
    )
    #expect(generated.versions == ["6.2", "6.3"])
  }

  @Test("The lowest of all manifests wins")
  func lowestManifestWins() throws {
    let generated = try Generator.run(
      ["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["6.0","6.1","6.2"]"#],
      manifests: [
        "Package.swift": Generator.manifest(toolsVersion: "6.2"),
        "Package@swift-6.1.swift": Generator.manifest(toolsVersion: "6.1"),
      ]
    )
    #expect(generated.versions == ["6.1", "6.2"])
  }

  @Test("An explicit minimum overrides the manifest")
  func explicitMinimum() throws {
    let generated = try Generator.run(
      [
        "ENABLE_LINUX": "true",
        "LINUX_SWIFT_VERSIONS": #"["6.1","6.2","6.3"]"#,
        "MINIMUM_SWIFT_VERSION": "6.3",
      ],
      manifests: ["Package.swift": Generator.manifest(toolsVersion: "6.1")]
    )
    #expect(generated.versions == ["6.3"])
  }

  @Test("A minimum of none disables filtering")
  func noneDisablesFiltering() throws {
    let generated = try Generator.run(
      [
        "ENABLE_LINUX": "true",
        "LINUX_SWIFT_VERSIONS": #"["6.1","6.3"]"#,
        "MINIMUM_SWIFT_VERSION": "none",
      ],
      manifests: ["Package.swift": Generator.manifest(toolsVersion: "6.3")]
    )
    #expect(generated.versions == ["6.1", "6.3"])
  }

  @Test("Nightlies are never filtered out")
  func nightliesSurviveFiltering() throws {
    let generated = try Generator.run(
      ["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["6.1","nightly-main","nightly-release"]"#],
      manifests: ["Package.swift": Generator.manifest(toolsVersion: "6.3")]
    )
    #expect(generated.versions == ["nightly-main", "nightly-release"])
  }
}

@Suite("Toolchain resolution")
struct ToolchainResolutionTests {
  @Test("A stable version needs no resolved forms")
  func stableVersion() throws {
    let generated = try Generator.run(["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["6.3"]"#])
    let build = try #require(generated.entries.first?.swiftBuild)
    #expect(build.swiftVersion == "6.3")
    #expect(build.toolchain == nil)
    #expect(build.swiftly == nil)
  }

  @Test("nightly-release keeps the label and carries both resolved forms")
  func nightlyRelease() throws {
    let generated = try Generator.run(["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["nightly-release"]"#])
    let build = try #require(generated.entries.first?.swiftBuild)
    #expect(build.swiftVersion == "nightly-release")
    #expect(build.toolchain == "nightly-6.4.x")
    // swiftly's release-snapshot grammar takes only major.minor.
    #expect(build.swiftly == "6.4-snapshot")
  }

  @Test("The branch token is data, so it can be moved at a branch cut")
  func tokenIsConfigurable() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["nightly-release"]"#,
      "NIGHTLY_RELEASE_TOKEN": "6.5",
    ])
    let build = try #require(generated.entries.first?.swiftBuild)
    #expect(build.toolchain == "nightly-6.5")
    #expect(build.swiftly == "6.5-snapshot")
  }

  @Test("nightly-main resolves only the swiftly selector")
  func nightlyMain() throws {
    let generated = try Generator.run(["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["nightly-main"]"#])
    let build = try #require(generated.entries.first?.swiftBuild)
    #expect(build.toolchain == nil, "the toolchain matches the label, so it should be omitted")
    #expect(build.swiftly == "main-snapshot")
  }

  @Test(
    "A branch named directly resolves like the alias",
    arguments: [("nightly-6.4.x", "6.4-snapshot"), ("nightly-6.2", "6.2-snapshot")]
  )
  func literalBranchNightly(version: String, expectedSelector: String) throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["\#(version)"]"#,
    ])
    #expect(generated.entries.first?.swiftBuild?.swiftly == expectedSelector)
  }
}

@Suite("Linux runners and containers")
struct LinuxTests {
  @Test("Architecture selects the runner")
  func architectureToRunner() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "LINUX_HOST_ARCHS": #"["x86_64","aarch64"]"#,
    ])
    #expect(generated.entries.map { $0.runner.first } == ["ubuntu-24.04", "ubuntu-24.04-arm"])
  }

  @Test("Linux is native until Docker is asked for")
  func nativeByDefault() throws {
    let native = try Generator.run(["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["6.3"]"#])
    #expect(native.entries.first?.swiftBuild?.container == nil)

    let containerised = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "LINUX_USE_DOCKER": "true",
    ])
    #expect(containerised.entries.first?.swiftBuild?.container?.image == "swift:6.3-noble")
  }

  @Test("A release-branch nightly is containerised even when native was asked for")
  func releaseBranchNightlyNeedsAContainer() throws {
    // swiftly's selector parser takes only major.minor for a release snapshot, so
    // 6.4.x has to be given as 6.4 — which asks for dev/6.4 while the published
    // directory is dev/6.4.x, and the install 404s. The container tag carries the
    // full token and does exist, so the entry has to use one.
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3","nightly-release","nightly-main"]"#,
    ])
    #expect(generated.entry(named: "Linux Swift 6.3")?.swiftBuild?.container == nil)
    #expect(generated.entry(named: "Linux Swift nightly-main")?.swiftBuild?.container == nil)
    #expect(
      generated.entry(named: "Linux Swift nightly-release")?.swiftBuild?.container?.image
        == "swiftlang/swift:nightly-6.4.x-noble"
    )
  }

  @Test(
    "Nightly images come from the nightly registry",
    arguments: [
      ("nightly-release", "swiftlang/swift:nightly-6.4.x-noble"),
      ("nightly-main", "swiftlang/swift:nightly-main-noble"),
      ("6.3", "swift:6.3-noble"),
    ]
  )
  func containerImages(version: String, expectedImage: String) throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_USE_DOCKER": "true",
      "LINUX_SWIFT_VERSIONS": #"["\#(version)"]"#,
    ])
    #expect(generated.entries.first?.swiftBuild?.container?.image == expectedImage)
  }

  @Test("An OS list forces Docker and multiplies the entries")
  func osList() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "LINUX_OS_VERSIONS": #"["jammy","noble"]"#,
    ])
    #expect(generated.count == 2)
    #expect(
      generated.entries.compactMap { $0.swiftBuild?.container?.image } == [
        "swift:6.3-jammy", "swift:6.3-noble",
      ]
    )
    #expect(generated.names == ["Linux Swift 6.3 jammy", "Linux Swift 6.3 noble"])
  }

  @Test("Container capabilities and security options are carried")
  func containerKnobs() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "LINUX_USE_DOCKER": "true",
      "LINUX_DOCKER_CAPABILITIES": #"["CAP_BPF"]"#,
      "LINUX_DOCKER_SECURITY_OPTIONS": #"["apparmor=unconfined"]"#,
    ])
    let container = try #require(generated.entries.first?.swiftBuild?.container)
    #expect(container.capabilities == ["CAP_BPF"])
    #expect(container.securityOptions == ["apparmor=unconfined"])
  }

  @Test("A Dockerfile implies container mode and keeps the base image")
  func dockerfileImpliesContainer() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "LINUX_DOCKERFILE": "docker/ci.Dockerfile",
    ])
    let container = try #require(generated.entries.first?.swiftBuild?.container)
    #expect(container.dockerfile == "docker/ci.Dockerfile")
    #expect(container.image == "swift:6.3-noble")
  }

  @Test("Unset container knobs are omitted rather than emitted empty")
  func knobsOmittedWhenUnset() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "LINUX_USE_DOCKER": "true",
    ])
    let container = try #require(generated.entries.first?.swiftBuild?.container)
    #expect(container.dockerfile == nil)
    #expect(container.capabilities == nil)
    #expect(container.securityOptions == nil)
  }
}

@Suite("Commands, arguments and overrides")
struct CommandTests {
  @Test("The build and pre-build commands are carried")
  func commandsCarried() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "LINUX_BUILD_COMMAND": "swift test --verbose",
      "LINUX_PRE_BUILD_COMMAND": "cd sub",
    ])
    #expect(generated.entries.first?.command == "swift test --verbose")
    #expect(generated.entries.first?.setupCommand == "cd sub")
  }

  @Test("Releases take swift_flags and nightlies take swift_nightly_flags")
  func flagSelection() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3","nightly-main"]"#,
      "SWIFT_FLAGS": "-Xswiftc -DRELEASE",
      "SWIFT_NIGHTLY_FLAGS": "-Xswiftc -DNIGHTLY",
    ])
    #expect(generated.entries[0].commandArguments == ["-Xswiftc", "-DRELEASE"])
    #expect(generated.entries[1].commandArguments == ["-Xswiftc", "-DNIGHTLY"])
  }

  @Test("A string override appends arguments and leaves the command alone")
  func stringOverride() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.2","6.3"]"#,
      "LINUX_VERSION_OVERRIDES": #"{"6.3": "-Xswiftc -warnings-as-errors"}"#,
    ])
    #expect(generated.entries[0].commandArguments == [], "an untargeted version is untouched")
    #expect(generated.entries[1].commandArguments == ["-Xswiftc", "-warnings-as-errors"])
    #expect(generated.entries[1].command == "swift test")
  }

  @Test("An object override can replace the command")
  func objectOverride() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "LINUX_VERSION_OVERRIDES": """
      6.3:
        command: swift build
        arguments: --explicit-target-dependency-import-check error
      """,
    ])
    #expect(generated.entries.first?.command == "swift build")
    #expect(
      generated.entries.first?.commandArguments == [
        "--explicit-target-dependency-import-check", "error",
      ]
    )
  }

  @Test("An override key matching no version warns")
  func unmatchedOverrideWarns() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "LINUX_VERSION_OVERRIDES": #"{"6.9": "-x"}"#,
    ])
    #expect(generated.standardError.contains("6.9"))
  }

  @Test(
    "Environment variables reach the entry",
    arguments: [
      (["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["6.3"]"#, "LINUX_ENV_VARS": #"{"FOO":"bar"}"#], "bar"),
      (["ENABLE_WINDOWS": "true", "WINDOWS_SWIFT_VERSIONS": #"["6.3"]"#, "WINDOWS_ENV_VARS": "FOO: baz"], "baz"),
    ]
  )
  func environmentVariables(environment: [String: String], expected: String) throws {
    let generated = try Generator.run(environment)
    #expect(generated.entries.first?.env["FOO"] == expected)
  }
}
