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

@Suite("macOS")
struct MacOSTests {
  @Test("A macOS entry names either a Swift version or an Xcode version, not both")
  func selector() throws {
    let bySwift = try Generator.run(["ENABLE_MACOS": "true", "MACOS_SWIFT_VERSIONS": #"["6.3"]"#])
    let swiftBuild = try #require(bySwift.entries.first?.xcodeBuild)
    #expect(swiftBuild.swiftVersion == "6.3")
    #expect(swiftBuild.xcodeVersion == nil)

    let byXcode = try Generator.run(["ENABLE_MACOS": "true", "MACOS_XCODE_VERSIONS": #"["26.3"]"#])
    let xcodeBuild = try #require(byXcode.entries.first?.xcodeBuild)
    #expect(xcodeBuild.xcodeVersion == "26.3")
    #expect(xcodeBuild.swiftVersion == nil)
  }

  @Test("The two macOS version lists combine rather than one replacing the other")
  func versionListsCombine() throws {
    // They are different ways of naming a toolchain, not competing spellings of
    // one. NIO's macOS configuration wants a pinned Xcode beta alongside the
    // release versions, which needs an entry from each list.
    let generated = try Generator.run([
      "ENABLE_MACOS": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.2","6.3"]"#,
      "MACOS_XCODE_VERSIONS": #"["latest-beta"]"#,
    ])
    #expect(generated.names == ["macOS Xcode latest-beta", "macOS Swift 6.2", "macOS Swift 6.3"])
  }

  @Test("The minimum Swift version filters macOS as it does every other platform")
  func minimumVersionAppliesToMacOS() throws {
    // A toolchain below the manifest's tools version cannot resolve the package,
    // so a macOS job on it fails for a reason the caller did not ask about.
    let generated = try Generator.run([
      "ENABLE_LINUX": "true",
      "ENABLE_MACOS": "true",
      "MINIMUM_SWIFT_VERSION": "6.2",
      "LINUX_SWIFT_VERSIONS": #"["6.0","6.1","6.2"]"#,
      "MACOS_SWIFT_VERSIONS": #"["6.0","6.1","6.2"]"#,
    ])
    #expect(generated.names == ["Linux Swift 6.2", "macOS Swift 6.2"])
  }

  @Test("Runner labels come from the OS, architecture and pool")
  func runnerLabels() throws {
    let generated = try Generator.run([
      "ENABLE_MACOS": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "MACOS_OS": "sequoia",
      "MACOS_ARCH": "X64",
      "MACOS_RUNNER_POOL": "nightly",
    ])
    #expect(generated.entries.first?.runner == ["self-hosted", "macos", "sequoia", "X64", "nightly"])
  }

  @Test("Only the enabled xcodebuild platforms get a target")
  func targetsFollowEnables() throws {
    let generated = try Generator.run([
      "ENABLE_MACOS": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "XCODE_SCHEME": "P-Package",
      "ENABLE_IOS_XCODE_BUILD": "true",
      "ENABLE_WATCHOS_XCODE_TEST": "true",
    ])
    let targets = try #require(generated.entries.first?.xcodeBuild?.targets)
    #expect(targets.map(\.platform) == ["iOS", "watchOS"])
    #expect(targets[0].build == true)
    #expect(targets[0].test == false)
    #expect(targets[1].test == true)
    #expect(targets[0].scheme == "P-Package")
  }

  @Test("macOS and Mac Catalyst are available as destinations")
  func macOSAndCatalystTargets() throws {
    let generated = try Generator.run([
      "ENABLE_MACOS": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "XCODE_SCHEME": "P-Package",
      "ENABLE_MACOS_XCODE_BUILD": "true",
      "ENABLE_CATALYST_XCODE_BUILD": "true",
    ])
    let targets = try #require(generated.entries.first?.xcodeBuild?.targets)
    #expect(targets.map(\.platform) == ["macOS", "Catalyst"])
    #expect(targets[1].buildDestination == "generic/platform=macos,variant=Mac Catalyst")
  }

  @Test("A target without a scheme fails rather than building nothing")
  func targetsNeedAScheme() throws {
    // xcodebuild has nothing to build without a scheme, so the entry would carry
    // an empty target list and the job would pass having checked nothing. This is
    // the first thing a caller migrating off enable_ios_checks hits.
    let generated = try Generator.run([
      "ENABLE_MACOS": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "ENABLE_IOS_XCODE_BUILD": "true",
    ])
    #expect(generated.exitCode != 0)
    #expect(generated.standardError.contains("xcode_scheme"))
  }

  @Test("An Apple-platform target without macOS fails rather than generating nothing")
  func targetsNeedMacOS() throws {
    // The targets ride on a macOS entry, so without one there is nothing for them
    // to attach to and the matrix comes out empty.
    let generated = try Generator.run([
      "XCODE_SCHEME": "P-Package",
      "ENABLE_IOS_XCODE_BUILD": "true",
    ])
    #expect(generated.exitCode != 0)
    #expect(generated.standardError.contains("enable_macos"))
  }

  @Test("The debug-output flag reaches the entry")
  func debugOutput() throws {
    let generated = try Generator.run([
      "ENABLE_MACOS": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "XCODE_DEBUG_OUTPUT": "true",
    ])
    #expect(generated.entries.first?.xcodeBuild?.debugOutput == true)
  }

  @Test("A swiftly toolchain pairs a selector with an Xcode, and may override the runner")
  func swiftlyToolchains() throws {
    let generated = try Generator.run([
      "ENABLE_MACOS_SWIFTLY": "true",
      "MACOS_SWIFTLY_TOOLCHAINS":
        #"[{"xcode_version":"swift_6.3","swiftly_toolchain":"main-snapshot","os_version":"sequoia","arch":"X64"}]"#,
      "MACOS_SWIFTLY_BUILD_COMMAND": "swiftly run swift build",
    ])
    let entry = try #require(generated.entries.first)
    #expect(entry.xcodeBuild?.xcodeVersion == "swift_6.3")
    #expect(entry.xcodeBuild?.swiftlyToolchain == "main-snapshot")
    #expect(entry.runner == ["self-hosted", "macos", "sequoia", "X64", "general"])
    #expect(entry.command == "swiftly run swift build")
  }

  @Test("A snapshot selector takes the nightly flags")
  func swiftlySnapshotTakesNightlyFlags() throws {
    let generated = try Generator.run([
      "ENABLE_MACOS_SWIFTLY": "true",
      "SWIFT_FLAGS": "-Xswiftc -DRELEASE",
      "SWIFT_NIGHTLY_FLAGS": "-Xswiftc -DNIGHTLY",
    ])
    #expect(generated.entries.first?.commandArguments == ["-Xswiftc", "-DNIGHTLY"])
  }

  @Test("A swiftly entry missing either version is skipped with a warning")
  func incompleteSwiftlyEntry() throws {
    let generated = try Generator.run([
      "ENABLE_MACOS_SWIFTLY": "true",
      "MACOS_SWIFTLY_TOOLCHAINS": #"[{"swiftly_toolchain":"main-snapshot"}]"#,
    ])
    #expect(generated.count == 0)
    #expect(generated.standardError.contains("WARNING"))
  }

  @Test("Self-hosted entries are withheld from other owners")
  func ownerGuard() throws {
    let matching = try Generator.run([
      "ENABLE_MACOS": "true",
      "ENABLE_MACOS_SWIFTLY": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "MACOS_REPOSITORY_OWNER": "apple",
      "GITHUB_REPOSITORY_OWNER": "apple",
    ])
    #expect(matching.count == 2)

    let fork = try Generator.run([
      "ENABLE_MACOS": "true",
      "ENABLE_MACOS_SWIFTLY": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "MACOS_REPOSITORY_OWNER": "apple",
      "GITHUB_REPOSITORY_OWNER": "a-fork",
    ])
    #expect(fork.count == 0, "a fork cannot reach the pools, so it should get no jobs at all")

    let unguarded = try Generator.run([
      "ENABLE_MACOS": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "GITHUB_REPOSITORY_OWNER": "a-fork",
    ])
    #expect(unguarded.count == 1)
  }
}

@Suite("Apple platform targets")
struct ApplePlatformTargetTests {
  /// Every platform NIO builds and tests, and the destinations each uses.
  @Test(
    "Each platform has a build and a test destination",
    arguments: [
      ("MACOS", "macOS", "generic/platform=macos,variant=macos", "name=My Mac,variant=macos"),
      (
        "CATALYST", "Catalyst", "generic/platform=macos,variant=Mac Catalyst",
        "name=My Mac,variant=Mac Catalyst"
      ),
      ("IOS", "iOS", "generic/platform=ios", "name=iPhone Air"),
      ("WATCHOS", "watchOS", "generic/platform=watchos", "name=Apple Watch Ultra 3 (49mm)"),
      ("TVOS", "tvOS", "generic/platform=tvos", "name=Apple TV 4K (3rd generation)"),
      ("VISIONOS", "visionOS", "generic/platform=visionos", "name=Apple Vision Pro"),
    ]
  )
  func destinations(
    key: String,
    platform: String,
    buildDestination: String,
    testDestination: String
  ) throws {
    let generated = try Generator.run([
      "ENABLE_MACOS": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "XCODE_SCHEME": "P-Package",
      "ENABLE_\(key)_XCODE_BUILD": "true",
      "ENABLE_\(key)_XCODE_TEST": "true",
    ])
    let targets = try #require(generated.entries.first?.xcodeBuild?.targets)
    #expect(targets.map(\.platform) == [platform])
    #expect(targets[0].buildDestination == buildDestination)
    #expect(targets[0].testDestination == testDestination)
    #expect(targets[0].build == true)
    #expect(targets[0].test == true)
  }

  @Test("Building for a platform is independent of testing on it")
  func buildWithoutTest() throws {
    // The build action is build-for-testing, so enabling build alone still
    // type-checks the tests — which is what the retired enable_ios_checks did,
    // without a runner of its own.
    let generated = try Generator.run([
      "ENABLE_MACOS": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "XCODE_SCHEME": "P-Package",
      "ENABLE_IOS_XCODE_BUILD": "true",
    ])
    let targets = try #require(generated.entries.first?.xcodeBuild?.targets)
    #expect(targets.count == 1)
    #expect(targets[0].build == true)
    #expect(targets[0].test == false)
  }

  @Test("Apple platform targets ride on the macOS entries rather than their own")
  func noExtraRunners() throws {
    // NIO's reason for this shape: a separate runner per platform is expensive,
    // because macOS runner recycling is slow.
    let generated = try Generator.run([
      "ENABLE_MACOS": "true",
      "MACOS_SWIFT_VERSIONS": #"["6.3"]"#,
      "XCODE_SCHEME": "P-Package",
      "ENABLE_IOS_XCODE_BUILD": "true",
      "ENABLE_WATCHOS_XCODE_BUILD": "true",
      "ENABLE_TVOS_XCODE_BUILD": "true",
      "ENABLE_VISIONOS_XCODE_BUILD": "true",
    ])
    #expect(generated.count == 1)
    #expect(generated.entries.first?.xcodeBuild?.targets?.count == 4)
  }
}

@Suite("Windows")
struct WindowsTests {
  @Test("The runner comes from the OS list, which also names the job")
  func runnersFromOSList() throws {
    let generated = try Generator.run([
      "ENABLE_WINDOWS": "true",
      "WINDOWS_SWIFT_VERSIONS": #"["6.3"]"#,
      "WINDOWS_OS_VERSIONS": #"["windows-2022","windows-11-arm"]"#,
    ])
    #expect(generated.entries.map { $0.runner.first } == ["windows-2022", "windows-11-arm"])
    #expect(generated.names == ["Windows Swift 6.3 windows-2022", "Windows Swift 6.3 windows-11-arm"])
  }

  @Test("Container images use the Windows tag")
  func containerImage() throws {
    let generated = try Generator.run([
      "ENABLE_WINDOWS": "true",
      "WINDOWS_SWIFT_VERSIONS": #"["nightly-release"]"#,
      "WINDOWS_USE_DOCKER": "true",
    ])
    #expect(
      generated.entries.first?.swiftBuild?.container?.image
        == "swiftlang/swift:nightly-6.4.x-windowsservercore-ltsc2022"
    )
  }
}
