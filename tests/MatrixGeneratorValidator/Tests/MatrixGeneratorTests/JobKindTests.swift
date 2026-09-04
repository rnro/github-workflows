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

import Foundation
import MatrixTestSupport
import Testing

@Suite("SDK builds")
struct SDKTests {
  @Test(
    "Each SDK kind declares its type",
    arguments: [
      ("ENABLE_LINUX_STATIC_SDK_BUILD", "LINUX_STATIC_SDK_VERSIONS", "static-linux"),
      ("ENABLE_WASM_SDK_BUILD", "WASM_SDK_VERSIONS", "wasm"),
      ("ENABLE_EMBEDDED_WASM_SDK_BUILD", "EMBEDDED_WASM_SDK_VERSIONS", "wasm-embedded"),
    ]
  )
  func sdkType(enableKey: String, versionsKey: String, expectedType: String) throws {
    let generated = try Generator.run([enableKey: "true", versionsKey: #"["6.3"]"#])
    #expect(generated.entries.first?.swiftBuild?.sdk?.type == expectedType)
  }

  @Test("An SDK entry keeps the label and carries the toolchain the SDK script needs")
  func labelAndToolchain() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX_STATIC_SDK_BUILD": "true",
      "LINUX_STATIC_SDK_VERSIONS": #"["nightly-release"]"#,
    ])
    let build = try #require(generated.entries.first?.swiftBuild)
    #expect(build.version == "nightly-release")
    // The SDK script derives swift.org paths from this, so the label alone would
    // give it dev/release.
    #expect(build.toolchain == "nightly-6.4.x")
  }

  @Test("The SDK pre-build command is carried")
  func preBuildCommand() throws {
    let generated = try Generator.run([
      "ENABLE_LINUX_STATIC_SDK_BUILD": "true",
      "LINUX_STATIC_SDK_VERSIONS": #"["6.3"]"#,
      "LINUX_STATIC_SDK_PRE_BUILD_COMMAND": "cd sub",
    ])
    // The SDK script builds in the working directory, so this is the only way to
    // reach a package that is not at the repository root.
    #expect(generated.entries.first?.setupCommand == "cd sub")
  }

  @Test("Android entries carry an NDK version each and the triples")
  func androidNDKAndTriples() throws {
    let generated = try Generator.run([
      "ENABLE_ANDROID_SDK_BUILD": "true",
      "ANDROID_SDK_VERSIONS": #"["6.3"]"#,
      "ANDROID_NDK_VERSIONS": #"["r27d","r28c"]"#,
      "ANDROID_TRIPLES": #"["aarch64-unknown-linux-android28"]"#,
    ])
    #expect(generated.count == 2)
    #expect(generated.entries.compactMap { $0.swiftBuild?.sdk?.ndkVersion } == ["r27d", "r28c"])
    #expect(generated.entries.first?.swiftBuild?.sdk?.triples == ["aarch64-unknown-linux-android28"])
  }

  @Test("Emulator checks ask the build for test binaries")
  func emulatorRequestsTestBinaries() throws {
    let withoutEmulator = try Generator.run([
      "ENABLE_ANDROID_SDK_BUILD": "true",
      "ANDROID_SDK_VERSIONS": #"["6.3"]"#,
      "ANDROID_NDK_VERSIONS": #"["r27d"]"#,
    ])
    #expect(withoutEmulator.entries.first?.androidEmulator == false)
    #expect(withoutEmulator.entries.first?.commandArguments == [])

    // The emulator script stages what the build produced, so without this there is
    // nothing to run.
    let withEmulator = try Generator.run([
      "ENABLE_ANDROID_SDK_BUILD": "true",
      "ENABLE_ANDROID_SDK_CHECKS": "true",
      "ANDROID_SDK_VERSIONS": #"["6.3"]"#,
      "ANDROID_NDK_VERSIONS": #"["r27d"]"#,
    ])
    #expect(withEmulator.entries.first?.androidEmulator == true)
    #expect(withEmulator.entries.first?.commandArguments == ["--build-tests"])
  }
}

@Suite("Release build and Cxx interop")
struct SupplementaryCheckTests {
  @Test("A release build defaults to the newest release version only")
  func releaseBuildScope() throws {
    let generated = try Generator.run([
      "ENABLE_RELEASE_BUILD": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.1","6.2","6.3","nightly-main"]"#,
    ])
    #expect(generated.count == 1)
    #expect(generated.entries.first?.swiftBuild?.version == "6.3")
    #expect(generated.entries.first?.command == "swift build -c release")
  }

  @Test("The release build list can be widened")
  func releaseBuildWidened() throws {
    let generated = try Generator.run([
      "ENABLE_RELEASE_BUILD": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.2","6.3"]"#,
      "RELEASE_BUILD_SWIFT_VERSIONS": #"["6.2","6.3"]"#,
    ])
    #expect(generated.count == 2)
  }

  @Test("Cxx interop defaults to one version and can enter a subdirectory")
  func cxxInteropScope() throws {
    let generated = try Generator.run([
      "ENABLE_CXX_INTEROP": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.2","6.3"]"#,
      "LINUX_PRE_BUILD_COMMAND": "cd sub",
    ])
    #expect(generated.count == 1)
    #expect(generated.entries.first?.swiftBuild?.version == "6.3")
    // check-cxx-interop.sh reads the manifest in the working directory.
    #expect(generated.entries.first?.setupCommand == "cd sub")
    #expect(generated.entries.first?.command == "${SCRIPTS_ROOT}/check-cxx-interop.sh")
  }

  @Test("Both run on the same distribution as the tests")
  func sameDistributionAsTests() throws {
    let generated = try Generator.run([
      "ENABLE_RELEASE_BUILD": "true",
      "ENABLE_CXX_INTEROP": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "LINUX_OS_VERSIONS": #"["jammy"]"#,
    ])
    let images = Set(generated.entries.compactMap { $0.swiftBuild?.container?.image })
    #expect(images == ["swift:6.3-jammy"])
  }
}

@Suite("FreeBSD")
struct FreeBSDTests {
  @Test("A FreeBSD entry carries its virtual machine configuration")
  func entryShape() throws {
    let generated = try Generator.run([
      "ENABLE_FREEBSD": "true",
      "FREEBSD_SWIFT_VERSIONS": #"["nightly-main"]"#,
      "FREEBSD_OS_VERSIONS": #"["14.3"]"#,
      "FREEBSD_BUILD_COMMAND": "swift build",
      "FREEBSD_PRE_BUILD_COMMAND": "cd sub",
      "FREEBSD_ENV_VARS": "FOO=bar",
    ])
    let entry = try #require(generated.entries.first)
    #expect(entry.platform == "FreeBSD")
    #expect(entry.freebsd?.osVersion == "14.3")
    #expect(entry.freebsd?.envVars == "FOO=bar")
    #expect(entry.command == "swift build")
    #expect(entry.setupCommand == "cd sub")
    // The executor derives SWIFT_VERSION from this. A FreeBSD entry has neither
    // swift_build nor xcode_build, so without it anything keyed on the version —
    // benchmark thresholds — would look under an empty directory name.
    #expect(entry.freebsd?.swiftVersion == "nightly-main")
  }
}

@Suite("Output modes")
struct OutputModeTests {
  @Test("Toolchain mode omits what the caller supplies instead")
  func toolchainsModeOmitsCommands() throws {
    let generated = try Generator.run([
      "MATRIX_MODE": "toolchains",
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
    ])
    let entry = try #require(generated.entries.first)
    #expect(entry.command == nil)
    #expect(entry.setupCommand == nil)
    #expect(entry.commandArguments == nil)
    // The toolchain itself is still fully described, and env describes what the
    // toolchain needs rather than the work.
    #expect(entry.swiftBuild?.version == "6.3")
    #expect(entry.runner == ["ubuntu-24.04"])
  }

  @Test("Toolchain mode suppresses the job kinds that exist only to run a command")
  func toolchainsModeSuppressesJobKinds() throws {
    let generated = try Generator.run([
      "MATRIX_MODE": "toolchains",
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
      "ENABLE_LINUX_STATIC_SDK_BUILD": "true",
      "ENABLE_CXX_INTEROP": "true",
      "ENABLE_RELEASE_BUILD": "true",
      "ENABLE_FREEBSD": "true",
    ])
    #expect(generated.names == ["Linux Swift 6.3"])
  }

  @Test("An unknown mode fails rather than guessing")
  func unknownModeFails() throws {
    let generated = try Generator.run(["MATRIX_MODE": "nonsense"])
    #expect(generated.exitCode != 0)
    #expect(generated.standardError.contains("MATRIX_MODE"))
  }

  @Test("YAML is the output format by default")
  func yamlByDefault() throws {
    let result = try Generator.runRaw(["ENABLE_LINUX": "true", "LINUX_SWIFT_VERSIONS": #"["6.3"]"#])
    #expect(result.standardOutput.hasPrefix("config:"))
  }

  @Test("JSON output can be asked for, which is what a decoder wants")
  func jsonOnRequest() throws {
    let result = try Generator.runRaw([
      "MATRIX_FORMAT": "json",
      "ENABLE_LINUX": "true",
      "LINUX_SWIFT_VERSIONS": #"["6.3"]"#,
    ])
    #expect(result.standardOutput.hasPrefix("{"))
  }

  @Test("An empty matrix is well formed in both output formats")
  func emptyMatrixInBothFormats() throws {
    let yaml = try Generator.runRaw()
    #expect(yaml.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "config: []")

    // run() asks for JSON and decodes it, so this covers the JSON form through the
    // same path every other test uses.
    let json = try Generator.run()
    #expect(json.count == 0)
    #expect(json.exitCode == 0)
  }

  @Test("An unknown output format fails rather than guessing")
  func unknownFormatFails() throws {
    let result = try Generator.runRaw(["MATRIX_FORMAT": "xml"])
    #expect(result.exitCode != 0)
    #expect(result.standardError.contains("MATRIX_FORMAT"))
  }
}

@Suite("Whole-matrix invariants")
struct InvariantTests {
  /// Everything enabled at once, which is the widest shape the generator produces.
  private func everything() throws -> Generated {
    try Generator.run(
      [
        "ENABLE_MACOS": "true",
        "ENABLE_FREEBSD": "true",
        "ENABLE_LINUX_STATIC_SDK_BUILD": "true",
        "ENABLE_WASM_SDK_BUILD": "true",
        "ENABLE_ANDROID_SDK_BUILD": "true",
        "ENABLE_RELEASE_BUILD": "true",
        "ENABLE_CXX_INTEROP": "true",
        "ENABLE_MACOS_SWIFTLY": "true",
        "XCODE_SCHEME": "P-Package",
        "ENABLE_IOS_XCODE_BUILD": "true",
        "ENABLE_WATCHOS_XCODE_BUILD": "true",
      ],
      includePlatformDefaults: true
    )
  }

  @Test("Every entry carries what the executor dispatches on")
  func everyEntryIsExecutable() throws {
    let generated = try everything()
    #expect(generated.count >= 15, "expected a substantial matrix, got \(generated.count)")

    for entry in generated.entries {
      #expect(!entry.platform.isEmpty)
      #expect(!entry.name.isEmpty)
      #expect(!entry.runner.isEmpty, "\(entry.name) has no runner")
      #expect(entry.command?.isEmpty == false, "\(entry.name) has no command")
    }
  }

  @Test("Every entry has exactly one toolchain model")
  func oneToolchainModelPerEntry() throws {
    let generated = try everything()
    for entry in generated.entries where entry.platform != "FreeBSD" {
      let models = [entry.swiftBuild != nil, entry.xcodeBuild != nil].filter { $0 }.count
      #expect(models == 1, "\(entry.name) has \(models) toolchain models; the dispatch assumes one")
    }
  }

  @Test("Job names are unique, since they are how a run is read")
  func namesAreUnique() throws {
    let generated = try everything()
    #expect(Set(generated.names).count == generated.count)
  }
}
