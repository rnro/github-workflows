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

// Generates the job matrix from the workflow's inputs, as generate-matrix.sh does:
// the same environment variables in, the same matrix on standard output, the same
// exit status. Run it with `swift generate-matrix.swift`.
//
// yq reads the YAML an input is written in and writes the YAML the matrix comes out
// as, and jq writes the JSON form. Everything between them is typed.

import Foundation

// MARK: - Configuration

/// What the run was configured with, as the caller wrote it.
struct Configuration {
  /// The releases a platform tests by default, oldest first.
  static let releases = ["6.1", "6.2", "6.3"]
  /// The nightlies every platform runs: the next release's branch, and main.
  static let nightlies = ["nightly-release", "nightly-main"]
  /// The most recent release, which the supplementary checks run on rather than every
  /// version: bumping a train means adding to `releases` and nothing else.
  static var latestRelease: String {
    guard let latest = releases.last else {
      fatal("Configuration.releases is empty, so no release is left for the supplementary checks to run on.")
    }
    return latest
  }
  /// The Swift versions a platform runs by default: every release, plus both nightlies.
  static let defaultVersions = releases + nightlies
  /// The Swift versions an SDK build runs by default. An SDK is newer than the releases that
  /// predate it, so running them would build against one that was never published.
  static let defaultSDKVersions = [latestRelease] + nightlies

  @Input("ENABLE_LINUX") var linuxEnabled = true
  @Input("ENABLE_MACOS") var macOSEnabled = false
  @Input("ENABLE_MACOS_SWIFTLY") var swiftlyEnabled = false
  @Input("ENABLE_WINDOWS") var windowsEnabled = true
  @Input("ENABLE_FREEBSD") var freeBSDEnabled = false
  @Input("ENABLE_ANDROID_EMULATOR_TESTS") var androidEmulatorEnabled = false
  @Input("ENABLE_CXX_INTEROP") var cxxInteropEnabled = false

  @Input("NIGHTLY_RELEASE_TOKEN") var nightlyReleaseToken = "6.4.x"
  @Input("SWIFT_FLAGS") var swiftFlags = ""
  @Input("SWIFT_NIGHTLY_FLAGS") var swiftNightlyFlags = ""
  @Input("MINIMUM_SWIFT_VERSION") var minimumSwiftVersion = ""
  @Input("ENABLE_SUBDIRECTORY_MANIFEST_SEARCH") var searchSubdirectories = false
  @Input("MATRIX_MODE") var matrixMode = "jobs"
  @Input("MATRIX_FORMAT") var matrixFormat = "yaml"

  @Input("LINUX_SWIFT_VERSIONS") var linuxVersions = Configuration.defaultVersions
  @Input("LINUX_OS") var linuxOS: OSList = "noble"
  @Input("LINUX_HOST_ARCHS") var linuxArchitectures = ["x86_64"]
  @Input("LINUX_COMMAND") var linuxCommands: Commands = "swift test"
  @Input("LINUX_SETUP_COMMAND") var linuxSetupCommand = ""
  @Input("LINUX_ENV_VARS") var linuxEnvironment = JSONValue.object([:])
  @Input("LINUX_VERSION_OVERRIDES") var linuxOverrides = VersionOverrides()
  @Input("LINUX_USE_DOCKER") var linuxUsesDocker = false
  @Input("LINUX_DOCKERFILE") var linuxDockerfile = ""
  @Input("LINUX_DOCKER_CAPABILITIES") var linuxCapabilities: [String] = []
  @Input("LINUX_DOCKER_SECURITY_OPTIONS") var linuxSecurityOptions: [String] = []

  @Input("MACOS_XCODE_VERSIONS") var macOSXcodeVersions: [String] = []
  @Input("MACOS_SWIFT_VERSIONS") var macOSVersions: [String] = []
  @Input("MACOS_OS") var macOSOS: OSList = "tahoe"
  @Input("MACOS_ARCH") var macOSArchitecture = "ARM64"
  @Input("MACOS_RUNNER_POOL") var macOSPool = "general"
  @Input("MACOS_COMMAND") var macOSCommands: Commands = "xcrun swift test"
  @Input("MACOS_SETUP_COMMAND") var macOSSetupCommand = ""
  @Input("MACOS_ENV_VARS") var macOSEnvironment = JSONValue.object([:])
  @Input("MACOS_VERSION_OVERRIDES") var macOSOverrides = VersionOverrides()
  /// The owner whose self-hosted macOS pools these entries need. Empty means no check.
  @Input("MACOS_REPOSITORY_OWNER") var macOSRepositoryOwner = ""
  @Input("GITHUB_REPOSITORY_OWNER") var repositoryOwner = ""
  @Input("XCODE_SCHEME") var xcodeScheme = ""
  @Input("XCODE_TARGETS") var xcodeTargets = ""
  @Input("XCODE_DEBUG_OUTPUT") var xcodeDebugOutput = false
  @Input("MACOS_SWIFTLY_TOOLCHAINS") var swiftlyToolchains = [
    SwiftlyToolchain(xcodeVersion: "swift_6.3", swiftlyToolchain: "main-snapshot")
  ]
  @Input("MACOS_SWIFTLY_COMMAND") var swiftlyCommands: Commands = "swiftly run swift test"

  @Input("WINDOWS_SWIFT_VERSIONS") var windowsVersions = Configuration.defaultVersions
  @Input("WINDOWS_OS") var windowsOS: OSList = "windows-2022"
  @Input("WINDOWS_COMMAND") var windowsCommands: Commands = "swift test"
  @Input("WINDOWS_SETUP_COMMAND") var windowsSetupCommand = ""
  @Input("WINDOWS_ENV_VARS") var windowsEnvironment = JSONValue.object([:])
  @Input("WINDOWS_VERSION_OVERRIDES") var windowsOverrides = VersionOverrides()
  @Input("WINDOWS_USE_DOCKER") var windowsUsesDocker = false

  @Input("ANDROID_NDK_VERSIONS") var androidNDKVersions = ["r27d", "r28c"]
  @Input("ANDROID_SDK_TRIPLES") var androidTriples = [
    "aarch64-unknown-linux-android28", "x86_64-unknown-linux-android28",
  ]

  @Input("CXX_INTEROP_SWIFT_VERSIONS") var cxxInteropVersions: [String] = []

  @Input("FREEBSD_SWIFT_VERSIONS") var freeBSDVersions = ["nightly-main"]
  @Input("FREEBSD_OS_VERSIONS") var freeBSDOSVersions = ["14.3"]
  @Input("FREEBSD_COMMAND") var freeBSDCommands: Commands = "swift test"
  @Input("FREEBSD_SETUP_COMMAND") var freeBSDSetupCommand = ""
  @Input("FREEBSD_ENV_VARS") var freeBSDEnvironmentVariables = ""

  /// Every per-version overrides input, so one no enabled group reads is still reported.
  var allOverrides: [VersionOverrides] { [self.linuxOverrides, self.macOSOverrides, self.windowsOverrides] }

  /// The SDK builds, which differ only in the prefix their inputs share, the SDK they build
  /// against and the name their jobs carry.
  static let sdkBuilds = [
    (prefix: "linux_static_sdk", type: "static-linux", name: "Static Linux SDK Swift"),
    (prefix: "wasm_sdk", type: "wasm", name: "Wasm SDK Swift"),
    (prefix: "embedded_wasm_sdk", type: "embedded-wasm", name: "Embedded Wasm SDK Swift"),
    (prefix: "android_sdk", type: "android", name: "Android SDK Swift"),
  ]
  var sdkInputs = Configuration.sdkBuilds.map { SDKInputs(prefix: $0.prefix) }

  /// One SDK build's inputs, by the prefix they share.
  func sdk(_ prefix: String) -> SDKInputs {
    guard let inputs = sdkInputs.first(where: { $0.prefix == prefix }) else {
      fatal("no SDK build is configured under \(prefix)")
    }
    return inputs
  }
}

/// What the matrix is for. In toolchains mode the caller supplies the command, so an entry
/// carries none of its own.
enum MatrixMode: String {
  case jobs
  case toolchains
}

/// The form the rest of the workflow parses the matrix with.
enum MatrixFormat: String {
  case yaml
  case json
}

// MARK: - Generating

struct Generator {
  private let configuration: Configuration
  private let mode: MatrixMode
  private let outputFormat: MatrixFormat
  private let minimum: MinimumVersion
  private let linuxOSNames: [String]
  private let linuxUsesDocker: Bool
  private let macOSVersions: [String]
  private let macOSSuppressed: Bool
  private let xcodeTargets: [XcodeTarget]
  private let cxxInteropVersions: [String]

  init(_ configuration: Configuration) {
    self.configuration = configuration
    self.mode = Generator.resolveMode(configuration)
    self.outputFormat = Generator.resolveFormat(configuration)
    Generator.validate(configuration, mode: self.mode)

    let linux = Generator.resolveLinuxOS(configuration)
    self.linuxOSNames = linux.names
    self.linuxUsesDocker = linux.usesDocker
    self.macOSVersions = Generator.resolveMacOSVersions(configuration)
    self.minimum = Generator.resolveMinimum(configuration)
    self.cxxInteropVersions = Generator.resolveCxxInteropVersions(configuration)
    // Resolved before the owner guard, so a fork — which gets no macOS entries at all — still
    // reports a target the caller got wrong.
    self.xcodeTargets = Generator.resolveXcodeTargets(configuration)
    self.macOSSuppressed = Generator.macOSIsSuppressed(configuration)
  }

  private static func resolveMode(_ configuration: Configuration) -> MatrixMode {
    guard let mode = MatrixMode(rawValue: configuration.matrixMode) else {
      fatal("MATRIX_MODE must be 'jobs' or 'toolchains', got '\(configuration.matrixMode)'")
    }
    return mode
  }

  private static func resolveFormat(_ configuration: Configuration) -> MatrixFormat {
    guard let format = MatrixFormat(rawValue: configuration.matrixFormat) else {
      fatal("MATRIX_FORMAT must be 'yaml' or 'json', got '\(configuration.matrixFormat)'")
    }
    return format
  }

  /// Fails on a pair of inputs that cannot both be honoured. Each would otherwise produce a
  /// matrix without the jobs the caller asked for.
  private static func validate(_ configuration: Configuration, mode: MatrixMode) {
    // Toolchains mode emits neither the emulator nor the build it runs, so the pairing only
    // has to hold where both could appear.
    if mode == .jobs && configuration.androidEmulatorEnabled && !configuration.sdk("android_sdk").enabled {
      fatal(
        "enable_android_emulator_tests needs enable_android_sdk_build; the emulator runs what that build produces."
      )
    }
    // An Apple-platform target rides on a macOS entry, so asking for one without enabling
    // macOS produces no jobs at all.
    if !configuration.xcodeTargets.isEmpty && !configuration.macOSEnabled {
      fatal("xcode_targets is set but enable_macos is false; xcodebuild targets run on macOS entries.")
    }
    // A Windows container shares the host's kernel, so an image built for another Windows
    // release does not start on it. ltsc2022 is the only Swift Windows image this repository
    // names, so any other label fails rather than being paired with one that cannot run.
    if configuration.windowsEnabled && configuration.windowsUsesDocker {
      for os in configuration.windowsOS.names where os != Toolchain.windowsDockerRunner {
        fatal(
          """
          No Swift Windows container image is known for \(os); windows_use_docker supports \
          windows-2022. Other labels have to run natively.
          """
        )
      }
    }
  }

  private static func resolveLinuxOS(_ configuration: Configuration) -> (names: [String], usesDocker: Bool) {
    let names = configuration.linuxOS.names
    var usesDocker = configuration.linuxUsesDocker || !configuration.linuxDockerfile.isEmpty
    if configuration.linuxOS.wasList {
      // A list names container images, so even a list of one runs in a container: left
      // native, the job would test the runner's own distribution and pass.
      if !usesDocker { log("linux_os names a list, so Linux runs in a container") }
      usesDocker = true
    } else if names != ["noble"] && !usesDocker {
      log("linux_os is \(names[0]) rather than noble, so Linux runs in a container")
      usesDocker = true
    }
    return (names, usesDocker)
  }

  /// The Swift versions the macOS entries run. The two macOS lists are different ways of
  /// naming a toolchain, not competing spellings of one, so they combine; the release list is
  /// the default only when neither is set.
  private static func resolveMacOSVersions(_ configuration: Configuration) -> [String] {
    if configuration.macOSVersions.isEmpty && configuration.macOSXcodeVersions.isEmpty {
      return Configuration.releases
    }
    return configuration.macOSVersions
  }

  private static func resolveMinimum(_ configuration: Configuration) -> MinimumVersion {
    if !configuration.minimumSwiftVersion.isEmpty {
      return MinimumVersion(configuration.minimumSwiftVersion)
    }
    let detected = detectMinimumVersion(includingSubdirectories: configuration.searchSubdirectories)
    if !detected.isEmpty { log("Auto-detected minimum Swift tools version: \(detected)") }
    return MinimumVersion(detected)
  }

  /// The Cxx interop check is supplementary rather than a full compatibility check, so it runs on
  /// the newest release in the Linux list unless a caller names more.
  private static func resolveCxxInteropVersions(_ configuration: Configuration) -> [String] {
    if configuration.cxxInteropVersions.isEmpty {
      return [newestRelease(in: configuration.linuxVersions)]
    }
    return configuration.cxxInteropVersions
  }

  /// macOS entries run on self-hosted pools a fork cannot reach, where its jobs would queue
  /// until they time out. Withholding them produces no jobs rather than jobs that cannot
  /// start, and the checks then treat macOS as a group this repository did not ask for.
  private static func macOSIsSuppressed(_ configuration: Configuration) -> Bool {
    let owner = configuration.macOSRepositoryOwner
    if owner.isEmpty || configuration.repositoryOwner.isEmpty || owner == configuration.repositoryOwner {
      return false
    }
    log("Skipping macOS entries: this repository's owner (\(configuration.repositoryOwner)) is not \(owner)")
    return true
  }

  /// The arguments an entry runs with: the flags for a nightly or for a release, plus
  /// anything its override adds.
  private func arguments(for version: String, _ overrides: VersionOverrides) -> [String] {
    let base = version.hasPrefix("nightly-") ? configuration.swiftNightlyFlags : configuration.swiftFlags
    return splitArguments("\(base) \(overrides.arguments(for: version))")
  }

  /// A flags input as the arguments it names. Globbing never happens, so a wildcard reaches
  /// the runner as the argument the caller wrote.
  private func splitArguments(_ flags: String) -> [String] {
    flags.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  private func container(_ toolchain: Toolchain, os: String) -> Container? {
    guard linuxUsesDocker else { return nil }
    return Container(
      image: toolchain.image(os: os),
      dockerfile: configuration.linuxDockerfile.isEmpty ? nil : configuration.linuxDockerfile,
      capabilities: configuration.linuxCapabilities.isEmpty ? nil : configuration.linuxCapabilities,
      securityOptions: configuration.linuxSecurityOptions.isEmpty ? nil : configuration.linuxSecurityOptions
    )
  }

  private func linuxRunner(_ architecture: String) -> [String] {
    [architecture == "aarch64" ? "ubuntu-24.04-arm" : "ubuntu-24.04"]
  }

  /// The architecture the SDK builds and the Cxx interop check run on: they do not fan out
  /// over architecture, so they follow the first one configured rather than a different
  /// default from the tests.
  private var primaryLinuxRunner: [String] {
    linuxRunner(configuration.linuxArchitectures.first ?? "x86_64")
  }
}

// MARK: - Assembling the job groups

extension Generator {
  private var linuxJobs: SwiftBuildJobs {
    SwiftBuildJobs(
      settings: JobGroupSettings(
        enableInput: "enable_linux",
        versionAxis: .list(input: "linux_swift_versions"),
        versions: configuration.linuxVersions,
        commandSource: .input(name: "linux_command"),
        commands: configuration.linuxCommands,
        overrides: configuration.linuxOverrides,
        namePrefix: "Linux Swift"
      ),
      setupCommand: configuration.linuxSetupCommand,
      environment: configuration.linuxEnvironment,
      minimum: minimum,
      releaseToken: configuration.nightlyReleaseToken,
      arguments: { self.arguments(for: $0.version, self.configuration.linuxOverrides) },
      operatingSystems: linuxOSNames,
      architectures: configuration.linuxArchitectures,
      runner: { architecture, _ in self.linuxRunner(architecture) },
      container: container
    )
  }

  private var macOSJobs: MacOSJobs {
    MacOSJobs(
      settings: JobGroupSettings(
        enableInput: "enable_macos",
        versionAxis: .list(input: "macos_swift_versions"),
        versions: macOSVersions,
        commandSource: .input(name: "macos_command"),
        commands: configuration.macOSCommands,
        overrides: configuration.macOSOverrides,
        versionsExemptFromMinimum: configuration.macOSXcodeVersions,
        namePrefix: "macOS Swift"
      ),
      operatingSystems: configuration.macOSOS.names,
      architecture: configuration.macOSArchitecture,
      pool: configuration.macOSPool,
      setupCommand: configuration.macOSSetupCommand,
      environment: configuration.macOSEnvironment,
      targets: xcodeTargets,
      debugOutput: configuration.xcodeDebugOutput,
      minimum: minimum,
      arguments: { self.arguments(for: $0, self.configuration.macOSOverrides) }
    )
  }

  private var macOSSwiftlyJobs: MacOSSwiftlyJobs {
    MacOSSwiftlyJobs(
      settings: JobGroupSettings(
        enableInput: "enable_macos_swiftly",
        versionAxis: .toolchains(input: "macos_swiftly_toolchains"),
        versions: [],
        commandSource: .input(name: "macos_swiftly_command"),
        commands: configuration.swiftlyCommands,
        namePrefix: "macOS Swiftly"
      ),
      toolchains: configuration.swiftlyToolchains,
      operatingSystems: configuration.macOSOS.names,
      architecture: configuration.macOSArchitecture,
      pool: configuration.macOSPool,
      setupCommand: configuration.macOSSetupCommand,
      environment: configuration.macOSEnvironment,
      arguments: {
        $0
          ? self.splitArguments(self.configuration.swiftNightlyFlags)
          : self.splitArguments(self.configuration.swiftFlags)
      }
    )
  }

  private var windowsJobs: SwiftBuildJobs {
    SwiftBuildJobs(
      settings: JobGroupSettings(
        enableInput: "enable_windows",
        versionAxis: .list(input: "windows_swift_versions"),
        versions: configuration.windowsVersions,
        commandSource: .input(name: "windows_command"),
        commands: configuration.windowsCommands,
        overrides: configuration.windowsOverrides,
        namePrefix: "Windows Swift"
      ),
      platform: "Windows",
      setupCommand: configuration.windowsSetupCommand,
      environment: configuration.windowsEnvironment,
      minimum: minimum,
      releaseToken: configuration.nightlyReleaseToken,
      arguments: { self.arguments(for: $0.version, self.configuration.windowsOverrides) },
      operatingSystems: configuration.windowsOS.names,
      runner: { _, os in [os] },
      container: { toolchain, _ in
        guard self.configuration.windowsUsesDocker else { return nil }
        return Container(image: toolchain.windowsImage)
      }
    )
  }

  private var cxxInteropJobs: SwiftBuildJobs {
    SwiftBuildJobs(
      settings: JobGroupSettings(
        enableInput: "enable_cxx_interop",
        versionAxis: .list(input: "cxx_interop_swift_versions"),
        versions: cxxInteropVersions,
        // The check is the command rather than a place to run one, so it takes none as input.
        // The runner expands SCRIPTS_ROOT, so that reference stays literal here.
        commandSource: .fixed,
        commands: "${SCRIPTS_ROOT}/check-cxx-interop.sh",
        overrides: configuration.linuxOverrides,
        namePrefix: "Cxx interop Swift"
      ),
      setupCommand: configuration.linuxSetupCommand,
      environment: configuration.linuxEnvironment,
      minimum: minimum,
      releaseToken: configuration.nightlyReleaseToken,
      arguments: { self.arguments(for: $0.version, self.configuration.linuxOverrides) },
      operatingSystems: linuxOSNames,
      runner: { _, _ in self.primaryLinuxRunner },
      container: container
    )
  }

  private var freeBSDJobs: FreeBSDJobs {
    FreeBSDJobs(
      settings: JobGroupSettings(
        enableInput: "enable_freebsd",
        versionAxis: .list(input: "freebsd_swift_versions"),
        versions: configuration.freeBSDVersions,
        commandSource: .input(name: "freebsd_command"),
        commands: configuration.freeBSDCommands,
        namePrefix: "FreeBSD"
      ),
      osVersions: configuration.freeBSDOSVersions,
      setupCommand: configuration.freeBSDSetupCommand,
      buildFlags: configuration.swiftNightlyFlags,
      environmentVariables: configuration.freeBSDEnvironmentVariables
    )
  }

  /// A group that builds against a Swift SDK. Its inputs all share one prefix, and it fans out
  /// over neither the distribution nor the architecture: install-and-build-with-sdk.sh
  /// fetches a toolchain matched to the SDK, and job-runner-linux.sh refuses an entry
  /// carrying both an sdk and a container.
  private func sdkJobs(
    _ build: (prefix: String, type: String, name: String),
    _ inputs: SDKInputs
  ) -> SwiftBuildJobs {
    var jobs = SwiftBuildJobs(
      settings: JobGroupSettings(
        enableInput: "enable_\(build.prefix)_build",
        versionAxis: .list(input: "\(build.prefix)_versions"),
        versions: inputs.versions,
        commandSource: .input(name: "\(build.prefix)_command"),
        commands: inputs.commands,
        overrides: configuration.linuxOverrides,
        namePrefix: build.name
      ),
      setupCommand: inputs.setupCommand,
      environment: configuration.linuxEnvironment,
      minimum: minimum,
      releaseToken: configuration.nightlyReleaseToken,
      arguments: { self.arguments(for: $0.version, self.configuration.linuxOverrides) },
      sdkType: build.type,
      runner: { _, _ in self.primaryLinuxRunner }
    )
    guard build.type == "android" else { return jobs }
    jobs.ndkVersions = configuration.androidNDKVersions
    jobs.triples = configuration.androidTriples
    jobs.androidEmulator = configuration.androidEmulatorEnabled
    // The emulator runs what the build produced, so the build is told to make test binaries.
    jobs.arguments = { _ in self.configuration.androidEmulatorEnabled ? ["--build-tests"] : [] }
    return jobs
  }

  /// The groups this run produces entries for, in the order the jobs are read in.
  ///
  /// A group nobody asked for is not built, so nothing it carries is read and nothing it
  /// carries can fail the run. This is the only place that asks whether a group is on.
  private var jobGroups: [any JobGroup] {
    var groups: [any JobGroup] = []
    if configuration.linuxEnabled { groups.append(linuxJobs) }
    // The macOS pools are self-hosted, and a fork cannot reach them.
    if configuration.macOSEnabled && !macOSSuppressed { groups.append(macOSJobs) }
    if configuration.swiftlyEnabled && !macOSSuppressed { groups.append(macOSSwiftlyJobs) }
    if configuration.windowsEnabled { groups.append(windowsJobs) }
    // A group that exists only to run a particular command has no meaning where the caller
    // supplies the command instead, so toolchains mode does not emit those.
    if mode == .toolchains { return groups }
    groups += zip(Configuration.sdkBuilds, configuration.sdkInputs)
      .filter { $0.1.enabled }
      .map(sdkJobs)
    if configuration.cxxInteropEnabled { groups.append(cxxInteropJobs) }
    if configuration.freeBSDEnabled { groups.append(freeBSDJobs) }
    return groups
  }
}

// MARK: - Producing the matrix

extension Generator {
  func generate() -> [MatrixEntry] {
    let groups = jobGroups

    // An overrides key is valid if it names a version in any enabled group that reads it: the
    // lists are independent, so a release build can name a version the test list does not.
    var readable: [String: [String]] = [:]
    for group in groups {
      readable[group.settings.overrides.name, default: []] += group.settings.selectableVersions
    }
    for overrides in configuration.allOverrides {
      overrides.validateKeys(against: Set(readable[overrides.name] ?? []).sorted())
    }

    for group in groups { group.validate(against: minimum) }

    let entries = groups.flatMap(\.entries)

    // An empty matrix is legitimate when nothing is enabled, and a mistake when something is:
    // the versions were all filtered out, or a list was empty. A deliberate skip — the fork
    // guard, or toolchains mode — leaves the enable off, so it counts as not enabled.
    if entries.isEmpty {
      let enabled = groups.map(\.settings.enableInput)
      guard enabled.isEmpty else {
        fatal(
          """
          No matrix entries, but these are enabled: \(enabled.joined(separator: " ")). Check the version \
          lists and minimum_swift_version — every version may have been filtered out.
          """
        )
      }
      log("No matrix entries: nothing is enabled")
    } else {
      log("Generated \(entries.count) matrix entries")
    }
    return entries
  }

  func write(_ entries: [MatrixEntry]) {
    var emitted = entries
    switch mode {
    case .jobs: ()
    case .toolchains:
      for index in emitted.indices {
        emitted[index].command = nil
        emitted[index].setupCommand = nil
        emitted[index].commandArguments = nil
      }
    }

    struct Matrix: Encodable {
      var config: [MatrixEntry]
    }
    let encoder = JSONEncoder()
    // Two runs of the same configuration have to produce the same matrix.
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json: Data
    do {
      json = try encoder.encode(Matrix(config: emitted))
    } catch {
      fatal("Could not encode the matrix: \(error)")
    }
    let written: String
    switch outputFormat {
    case .json: written = format(json, with: jq, ["."])
    case .yaml: written = format(json, with: yq, ["-P"])
    }
    print(written, terminator: "")
  }
}

// MARK: - Xcodebuild targets

extension Generator {
  /// The platforms to build and test through xcodebuild, which every macOS entry carries: a
  /// map of platform to that target's settings, or a list of platforms taking the defaults.
  ///
  /// The destinations name the newest device of each kind, which ages with every Xcode
  /// release, so a target can give its own instead.
  static func resolveXcodeTargets(_ configuration: Configuration) -> [XcodeTarget] {
    let destinations: [String: (build: String, test: String)] = [
      "macOS": (build: "generic/platform=macos,variant=macos", test: "name=My Mac,variant=macos"),
      "Catalyst": (
        build: "generic/platform=macos,variant=Mac Catalyst", test: "name=My Mac,variant=Mac Catalyst"
      ),
      "iOS": (build: "generic/platform=ios", test: "name=iPhone Air"),
      "watchOS": (build: "generic/platform=watchos", test: "name=Apple Watch Ultra 3 (49mm)"),
      "tvOS": (build: "generic/platform=tvos", test: "name=Apple TV 4K (3rd generation)"),
      "visionOS": (build: "generic/platform=visionos", test: "name=Apple Vision Pro"),
    ]

    let text = configuration.xcodeTargets
    if text.isEmpty { return [] }
    // A scalar is rejected rather than read as one platform: the parse is here only to tell a
    // map from a list, and the keys it yields have to match a platform below, so YAML
    // rewriting one cannot pass unnoticed.
    guard let parsed = parse(text) else {
      fatal("xcode_targets is not valid JSON or YAML: \(text)")
    }
    guard parsed.isCollection else {
      fatal(
        """
        xcode_targets takes a map, such as {iOS: {build: true}}, or a list, such as [iOS, watchOS], \
        but got: \(text)
        """
      )
    }

    // A list asks for each platform with every setting left at its default.
    var members = parsed.mapMembers.map { (platform: $0.key, settings: $0.value) }
    if let listed = parsed.value.asArray {
      guard listed.allSatisfy({ $0.asString != nil }) else {
        fatal("xcode_targets as a list takes platform names, such as [iOS, watchOS], but got: \(text)")
      }
      members = listed.map { (platform: $0.text, settings: JSONValue.object([:])) }
    }

    return members.map { platform, value in
      guard let defaults = destinations[platform] else {
        fatal(
          """
          xcode_targets names an unknown platform '\(platform)'; the platforms are macOS, Catalyst, iOS, \
          watchOS, tvOS and visionOS.
          """
        )
      }
      // A platform named with no settings is written `iOS:`, which parses as null.
      guard case .object(let settings) = (value.isNull ? .object([:]) : value) else {
        fatal("xcode_targets settings for \(platform) take the form {build: true, test: true}, but got: \(value)")
      }
      // A misspelled setting would otherwise be dropped and its default left in place: a
      // target carrying `sheme` would build the default scheme, or fail for the want of one.
      let unknown = Set(settings.keys)
        .subtracting(["build", "test", "scheme", "build_destination", "test_destination"]).sorted()
      guard unknown.isEmpty else {
        fatal(
          """
          xcode_targets settings for \(platform) include unknown keys: \(unknown.joined(separator: ", ")). \
          A target takes build, test, scheme, build_destination and test_destination.
          """
        )
      }

      func flag(_ key: String, or fallback: Bool) -> Bool {
        guard let setting = settings[key]?.nonNull else { return fallback }
        guard let value = setting.asBool else {
          fatal("xcode_targets settings for \(platform) take build and test as true or false, but got: \(value)")
        }
        return value
      }
      // Building is the default because a package can be built for every platform, while
      // testing needs a simulator and takes far longer.
      let build = flag("build", or: true)
      let test = flag("test", or: false)
      guard build || test else {
        fatal("xcode_targets asks for \(platform) with build and test both false, so the target would do nothing.")
      }

      let scheme = settings["scheme"]?.text ?? configuration.xcodeScheme
      if scheme.isEmpty {
        fatal(
          """
          xcode_targets names \(platform) but no scheme reaches it; set xcode_scheme, or give the target \
          its own. xcodebuild builds nothing without a scheme.
          """
        )
      }
      return XcodeTarget(
        platform: platform,
        scheme: scheme,
        buildDestination: settings["build_destination"]?.text ?? defaults.build,
        testDestination: settings["test_destination"]?.text ?? defaults.test,
        build: build,
        test: test
      )
    }
  }
}

// MARK: - Job groups

/// One group of jobs the matrix can hold: the entries one enable turns on.
protocol JobGroup {
  var settings: JobGroupSettings { get }
  /// In the order the jobs are read in.
  var entries: [MatrixEntry] { get }
  /// Fails on a configuration that would leave a job the caller asked for out of this group.
  func validate(against minimum: MinimumVersion)
}

extension JobGroup {
  /// The checks every group makes.
  func validateSettings(against minimum: MinimumVersion) {
    settings.validateCommandVersions()
    settings.validateReplaceableCommand()
    settings.validateRunnableVersions(minimum)
  }

  func validate(against minimum: MinimumVersion) {
    validateSettings(against: minimum)
  }
}

/// What a job group fans out over.
enum VersionAxis {
  /// A Swift version list, named by this input.
  case list(input: String)
  /// Swiftly-managed toolchains rather than a version list, named by this input, so a label
  /// has no versions to select from.
  case toolchains(input: String)

  /// The input a message names, so the caller knows which knob to turn.
  var inputName: String {
    switch self {
    case .list(let input): return input
    case .toolchains(let input): return input
    }
  }
}

/// Where a job group's command comes from.
enum CommandSource {
  /// The caller names it, in the input given, so a per-version `command:` override can replace
  /// it.
  case input(name: String)
  /// The command is the check itself rather than a place to run one, so an override replacing
  /// it would leave the job named for something it no longer does.
  case fixed

  /// The input a message names, or nil when the command is the check itself.
  var inputName: String? {
    switch self {
    case .input(let name): return name
    case .fixed: return nil
    }
  }
}

/// What a job group runs, and the inputs a message about it has to name.
struct JobGroupSettings {
  var enableInput: String
  var versionAxis: VersionAxis
  var versions: [String]
  var commandSource: CommandSource
  var commands: Commands
  var overrides = VersionOverrides()
  /// Versions a label may select that the minimum-version filter never sees. Only macOS has
  /// any: its Xcode list names Xcodes rather than Swift versions.
  var versionsExemptFromMinimum: [String] = []
  var namePrefix: String

  var selectableVersions: [String] {
    self.versionsExemptFromMinimum.isEmpty
      ? self.versions
      : Set(self.versions + self.versionsExemptFromMinimum).sorted()
  }
}

extension JobGroupSettings {
  /// Fails when a label selects a version the group does not run: the label contributes no
  /// entries, so the command the caller named is missing from a run that reports success.
  func validateCommandVersions() {
    guard let commandsInput = self.commandSource.inputName else { return }
    switch self.versionAxis {
    case .toolchains(let toolchainsInput):
      // Fanning out over toolchains leaves a label nothing to select from, so the versions it
      // names carry nothing.
      if self.commands.contains(where: { $0.swiftVersions != nil }) {
        fatal("\(commandsInput) takes no versions; its toolchains come from \(toolchainsInput).")
      }
    case .list:
      let selectable = self.selectableVersions
      let unmatched = self.commands.flatMap { variant in
        (variant.swiftVersions ?? []).filter { !selectable.contains($0) }.map { "\(variant.label): \($0)" }
      }
      guard unmatched.isEmpty else {
        fatal(
          """
          \(commandsInput) selects versions the matrix does not hold: \(unmatched.joined(separator: ", ")). \
          Valid versions: \(selectable.joined(separator: " "))
          """
        )
      }
    }
  }

  /// Fails when a per-version `command:` override has nothing to replace: with more than one
  /// command, honoring it would give every label the same one and leave jobs that differ only
  /// in name.
  func validateReplaceableCommand() {
    let replaced = self.overrides.versionsReplacingTheCommand(among: self.versions)
    if replaced.isEmpty { return }
    guard let commandsInput = self.commandSource.inputName else {
      fatal(
        """
        \(self.overrides.name) replaces the command for \(replaced.joined(separator: ", ")), which \
        "\(self.namePrefix)" also runs. Its command is the check itself, so replacing it would leave the \
        job named for something it no longer does. Drop the command from the override, or take that \
        version out of this group's version list.
        """
      )
    }
    guard self.commands.count > 1 else { return }
    fatal(
      """
      \(self.overrides.name) replaces the command for \(replaced.joined(separator: ", ")), but \
      \(commandsInput) has more than one command configured, so there is no single command to replace. \
      Give that label its own versions instead.
      """
    )
  }

  /// Fails when the minimum-version filter leaves the group, or one of its labels, nothing to
  /// run. Dropping some versions is the filter working; dropping all of them is a job the
  /// caller asked for and did not get, in a run that still reports success.
  func validateRunnableVersions(_ minimum: MinimumVersion) {
    // An empty list is a group given no versions rather than one the filter emptied; the
    // whole-matrix guard reports that against the enables.
    if self.versions.isEmpty { return }
    let runnable = self.versions.filter(minimum.admits)
    if runnable.isEmpty {
      fatal(
        """
        \(self.enableInput) is set, but the minimum Swift version \(minimum.text) removes every version in \
        \(self.versionAxis.inputName) (\(self.versions.joined(separator: " "))), so it would produce no \
        jobs. \(MinimumVersion.remedy)
        """
      )
    }
    guard let commandsInput = self.commandSource.inputName else { return }
    for variant in self.commands {
      // A label naming no versions of its own runs the group's whole list, which the check
      // above covers.
      guard let swiftVersions = variant.swiftVersions else { continue }
      guard variant.versions(among: self.versionsExemptFromMinimum + runnable).isEmpty else { continue }
      fatal(
        """
        \(commandsInput) label '\(variant.label)' runs only on \(swiftVersions.joined(separator: " ")), which \
        minimum Swift version \(minimum.text) removes, so that label would produce no jobs while the others \
        still run. \(MinimumVersion.remedy)
        """
      )
    }
  }
}

/// Assembles an entry name.
///
/// An axis with one value contributes nothing, and the label leads: entry names are required
/// status checks in adopting repositories, and a version and a label appended bare would run
/// together into one word.
func jobName(_ base: String, _ suffixes: String?..., label: String? = nil) -> String {
  let name = ([base] + suffixes.compactMap { $0 }).joined(separator: " ")
  guard let label, label.isEmpty == false else { return name }
  return "\(label) \(name)"
}

func macOSRunner(os: String, architecture: String, pool: String) -> [String] {
  ["self-hosted", "macos", os, architecture, pool]
}

fileprivate extension String {
  func ifEmpty(_ fallback: String) -> String {
    isEmpty ? fallback : self
  }
}

/// A group whose entries carry a `swift_build`: the Linux tests, the SDK builds, the Cxx
/// interop check and Windows. They differ in the axes they fan out over and in how a runner
/// and a container are derived.
struct SwiftBuildJobs: JobGroup {
  var settings: JobGroupSettings
  var platform = "Linux"
  var setupCommand = ""
  var environment = JSONValue.object([:])
  var minimum = MinimumVersion("")
  var releaseToken: String
  var arguments: (_ toolchain: Toolchain) -> [String] = { _ in [] }
  /// An axis the group does not have is one pass whose value nothing reads.
  var operatingSystems = ["-"]
  var architectures = ["-"]
  var ndkVersions: [String]?
  var sdkType: String?
  var triples: [String]?
  /// Set when the emulator runs what the build produced, which the executor reads.
  var androidEmulator: Bool?
  var runner: (_ architecture: String, _ os: String) -> [String] = { _, _ in [] }
  var container: (_ toolchain: Toolchain, _ os: String) -> Container? = { _, _ in nil }

  /// One entry's value from every axis.
  private struct Combination {
    var os: String
    var architecture: String
    var ndkVersion: String?
    var command: Commands.Command
    var version: String
  }

  /// In the order the jobs come out in.
  private var combinations: [Combination] {
    architectures.flatMap { architecture in
      operatingSystems.flatMap { os in
        (self.ndkVersions?.map(Optional.some) ?? [nil]).flatMap { ndk in
          settings.commands.flatMap { command in
            command.versions(among: settings.versions).filter(minimum.admits).map {
              Combination(os: os, architecture: architecture, ndkVersion: ndk, command: command, version: $0)
            }
          }
        }
      }
    }
  }

  var entries: [MatrixEntry] {
    return combinations.map { combination in
      let toolchain = Toolchain(version: combination.version, releaseToken: releaseToken)
      let sdk = sdkType.map { SDK(type: $0, ndkVersion: combination.ndkVersion, triples: triples) }
      // The group whose command is the check itself takes no per-version replacement.
      let command: String
      switch settings.commandSource {
      case .fixed:
        command = combination.command.command
      case .input:
        command = settings.overrides.command(for: combination.version).ifEmpty(combination.command.command)
      }
      return MatrixEntry(
        platform: platform,
        name: jobName(
          "\(settings.namePrefix) \(combination.version)",
          combination.ndkVersion.map { "NDK \($0)" },
          operatingSystems.count > 1 ? combination.os : nil,
          architectures.count > 1 ? combination.architecture : nil,
          label: settings.commands.nameLabel(for: combination.command)
        ),
        runner: runner(combination.architecture, combination.os),
        swiftBuild: SwiftBuild(toolchain, sdk: sdk, container: container(toolchain, combination.os)),
        setupCommand: setupCommand,
        command: command,
        commandArguments: arguments(toolchain),
        env: environment,
        androidEmulator: androidEmulator
      )
    }
  }
}

/// The macOS entries: one pass over the Xcode list, which names Xcodes, and one over the
/// Swift list, which names toolchains. A label's versions select from whichever list holds
/// them, so a label naming an Xcode contributes nothing to the Swift pass.
struct MacOSJobs: JobGroup {
  var settings: JobGroupSettings
  var operatingSystems: [String] = []
  var architecture = "ARM64"
  var pool = "general"
  var setupCommand = ""
  var environment = JSONValue.object([:])
  var targets: [XcodeTarget] = []
  var debugOutput = false
  var minimum = MinimumVersion("")
  var arguments: (_ version: String) -> [String] = { _ in [] }

  /// What the Xcode pass's entry names carry before the version. The Swift pass takes the
  /// group's own prefix.
  var xcodeNamePrefix = "macOS Xcode"

  private var xcodeVersions: [String] { settings.versionsExemptFromMinimum }

  var entries: [MatrixEntry] {
    return operatingSystems.flatMap { os in
      pass(xcodeVersions, os: os, namePrefix: xcodeNamePrefix, namesXcode: true)
        + pass(settings.versions, os: os, namePrefix: settings.namePrefix, namesXcode: false)
    }
  }

  private func pass(
    _ versions: [String],
    os: String,
    namePrefix: String,
    namesXcode: Bool
  ) -> [MatrixEntry] {
    if versions.isEmpty { return [] }
    return settings.commands.flatMap { command in
      // The Xcode list names Xcodes, which the minimum Swift version does not order.
      command.versions(among: versions).filter { namesXcode || minimum.admits($0) }.map { version in
        MatrixEntry(
          platform: "macOS",
          name: jobName(
            "\(namePrefix) \(version)",
            operatingSystems.count > 1 ? os : nil,
            label: settings.commands.nameLabel(for: command)
          ),
          runner: macOSRunner(os: os, architecture: architecture, pool: pool),
          xcodeBuild: XcodeBuild(
            swiftVersion: namesXcode ? nil : version,
            xcodeVersion: namesXcode ? version : nil,
            targets: targets,
            debugOutput: debugOutput
          ),
          setupCommand: setupCommand,
          command: settings.overrides.command(for: version).ifEmpty(command.command),
          commandArguments: arguments(version),
          env: environment
        )
      }
    }
  }
}

/// The macOS entries driven by a swiftly-managed toolchain, which fan out over the toolchains
/// rather than a version list.
struct MacOSSwiftlyJobs: JobGroup {
  var settings: JobGroupSettings
  var toolchains: [SwiftlyToolchain] = []
  var operatingSystems: [String] = []
  var architecture = "ARM64"
  var pool = "general"
  var setupCommand = ""
  var environment = JSONValue.object([:])
  var arguments: (_ isSnapshot: Bool) -> [String] = { _ in [] }

  func validate(against minimum: MinimumVersion) {
    validateSettings(against: minimum)
    // Skipping the entry would drop a job from a run that still reports success, which is how
    // a misspelled key goes unnoticed.
    for toolchain in toolchains where toolchain.xcodeVersion.isEmpty || toolchain.swiftlyToolchain.isEmpty {
      fatal(
        """
        macos_swiftly_toolchains entry needs both xcode_version and swiftly_toolchain: \
        xcode_version "\(toolchain.xcodeVersion)", swiftly_toolchain "\(toolchain.swiftlyToolchain)"
        """
      )
    }
  }

  var entries: [MatrixEntry] {
    return toolchains.flatMap { toolchain -> [MatrixEntry] in
      let osList = toolchain.osVersion.map { [$0] } ?? operatingSystems
      return osList.flatMap { os in
        settings.commands.map { command in
          MatrixEntry(
            platform: "macOS",
            name: jobName(
              "\(settings.namePrefix) \(toolchain.swiftlyToolchain) (Xcode \(toolchain.xcodeVersion))",
              operatingSystems.count > 1 ? os : nil,
              label: settings.commands.nameLabel(for: command)
            ),
            runner: macOSRunner(
              os: os,
              architecture: toolchain.architecture ?? architecture,
              pool: pool
            ),
            xcodeBuild: XcodeBuild(
              xcodeVersion: toolchain.xcodeVersion,
              swiftlyToolchain: toolchain.swiftlyToolchain
            ),
            setupCommand: setupCommand,
            command: command.command,
            // A snapshot takes the nightly flags, as a "nightly-" prefix does elsewhere.
            commandArguments: arguments(toolchain.swiftlyToolchain.contains("snapshot")),
            env: environment
          )
        }
      }
    }
  }
}

/// The FreeBSD entries, which carry a virtual machine rather than a toolchain.
struct FreeBSDJobs: JobGroup {
  var settings: JobGroupSettings
  var osVersions: [String] = []
  var setupCommand = ""
  var buildFlags = ""
  var environmentVariables = ""

  private static let toolchainURL =
    "https://download.swift.org/tmp-ci-nightly/development/freebsd-14_ci_latest.tar.gz"

  func validate(against minimum: MinimumVersion) {
    validateSettings(against: minimum)
    // One FreeBSD toolchain is published, so a version naming anything else would produce a
    // job labeled for a toolchain it does not install.
    for version in settings.versions where version != "nightly-main" {
      fatal("FreeBSD supports only the nightly-main Swift version, not '\(version)'.")
    }
    // The published tarballs are named by major release and only 14 has one, so any other OS
    // version would install a toolchain built for a release the job is not labeled for.
    for osVersion in osVersions where osVersion != "14" && !osVersion.hasPrefix("14.") {
      fatal("No Swift toolchain is published for FreeBSD \(osVersion); freebsd_os_versions supports 14 releases.")
    }
  }

  var entries: [MatrixEntry] {
    return osVersions.flatMap { osVersion in
      settings.commands.flatMap { command in
        command.versions(among: settings.versions).map { version in
          MatrixEntry(
            platform: "FreeBSD",
            name: jobName(
              "\(settings.namePrefix) \(version) - \(osVersion) - x86_64",
              label: settings.commands.nameLabel(for: command)
            ),
            runner: ["ubuntu-24.04"],
            freeBSDBuild: FreeBSDBuild(
              osVersion: osVersion,
              swiftVersion: version,
              swiftURL: FreeBSDJobs.toolchainURL,
              buildFlags: buildFlags,
              envVars: environmentVariables
            ),
            setupCommand: setupCommand,
            command: command.command,
            commandArguments: [],
            env: .object([:])
          )
        }
      }
    }
  }
}

// MARK: - Matrix entries

struct MatrixEntry: Encodable {
  var platform: String
  var name: String
  var runner: [String]
  var swiftBuild: SwiftBuild?
  var xcodeBuild: XcodeBuild?
  var freeBSDBuild: FreeBSDBuild?
  /// Absent in toolchains mode, where the caller supplies these instead. `env` stays: it
  /// describes what the toolchain needs rather than the work run on it.
  var setupCommand: String?
  var command: String?
  var commandArguments: [String]?
  var env: JSONValue
  var androidEmulator: Bool?

  enum CodingKeys: String, CodingKey {
    case platform, name, runner, command, env
    case swiftBuild = "swift_build"
    case xcodeBuild = "xcode_build"
    case freeBSDBuild = "freebsd"
    case setupCommand = "setup_command"
    case commandArguments = "command_arguments"
    case androidEmulator = "android_emulator"
  }
}

/// The toolchain a Linux or Windows entry runs. The resolved forms are carried only when they
/// differ from the label, so a hand-written matrix needs only `swift_version`.
struct SwiftBuild: Encodable {
  var swiftVersion: String
  var resolvedVersion: String?
  var swiftlySelector: String?
  var sdk: SDK?
  var container: Container?

  init(_ toolchain: Toolchain, sdk: SDK? = nil, container: Container? = nil) {
    self.swiftVersion = toolchain.version
    self.resolvedVersion = toolchain.resolved == toolchain.version ? nil : toolchain.resolved
    self.swiftlySelector = toolchain.swiftly == toolchain.version ? nil : toolchain.swiftly
    self.sdk = sdk
    self.container = container
  }

  enum CodingKeys: String, CodingKey {
    case sdk, container
    case swiftVersion = "swift_version"
    case resolvedVersion = "toolchain"
    case swiftlySelector = "swiftly"
  }
}

struct Container: Encodable {
  var image: String
  var dockerfile: String?
  var capabilities: [String]?
  var securityOptions: [String]?

  enum CodingKeys: String, CodingKey {
    case image, dockerfile, capabilities
    case securityOptions = "security_options"
  }
}

struct SDK: Encodable {
  var type: String
  /// An NDK release is part of which SDK a build is made against, so it belongs beside the
  /// triples.
  var ndkVersion: String?
  var triples: [String]?

  enum CodingKeys: String, CodingKey {
    case type, triples
    case ndkVersion = "ndk_version"
  }
}

/// The toolchain a macOS entry runs: an Xcode that ships one, or an Xcode with a
/// swiftly-managed toolchain installed under it.
struct XcodeBuild: Encodable {
  var swiftVersion: String?
  var xcodeVersion: String?
  var swiftlyToolchain: String?
  var targets: [XcodeTarget]?
  var debugOutput: Bool?

  enum CodingKeys: String, CodingKey {
    case targets
    case swiftVersion = "swift_version"
    case xcodeVersion = "xcode_version"
    case swiftlyToolchain = "swiftly_toolchain"
    case debugOutput = "debug_output"
  }
}

/// A step inside a macOS job rather than a job of its own.
struct XcodeTarget: Encodable {
  var platform: String
  var scheme: String
  var buildDestination: String
  var testDestination: String
  var build: Bool
  var test: Bool

  enum CodingKeys: String, CodingKey {
    case platform, scheme, build, test
    case buildDestination = "build_destination"
    case testDestination = "test_destination"
  }
}

struct FreeBSDBuild: Encodable {
  var osVersion: String
  /// The executor derives SWIFT_VERSION from this: a FreeBSD entry has no `swift_build`.
  var swiftVersion: String
  var swiftURL: String
  var buildFlags: String
  var envVars: String

  enum CodingKeys: String, CodingKey {
    case osVersion = "os_version"
    case swiftVersion = "swift_version"
    case swiftURL = "swift_url"
    case buildFlags = "build_flags"
    case envVars = "env_vars"
  }
}

// MARK: - Toolchains

/// A version label and the forms upstream publishes it under.
struct Toolchain {
  /// The only Windows runner a Swift container image is published for.
  static let windowsDockerRunner = "windows-2022"

  /// The label a caller wrote, such as `6.3` or `nightly-release`.
  let version: String
  /// The branch spelling upstream publishes the next release's nightly under, which
  /// `nightly-release` is an alias for: 6.0 through 6.3 were "6.<n>", 6.4 is "6.4.x".
  let releaseToken: String

  var isNightly: Bool { self.version.hasPrefix("nightly-") }

  /// The Docker tag infix, the Windows installer script suffix, and the argument
  /// install-and-build-with-sdk.sh takes.
  var resolved: String {
    let alias = "nightly-\(self.releaseToken)"
    return self.version == "nightly-release" || self.version == alias ? alias : self.version
  }

  /// The swiftly selector. The branch token names the release snapshot's own directory under
  /// dev/, and swiftly's release-snapshot grammar takes it whole, so it is passed through.
  var swiftly: String {
    guard self.resolved.hasPrefix("nightly-") else { return self.resolved }
    let branch = String(self.resolved.dropFirst("nightly-".count))
    return branch == "main" ? "main-snapshot" : "\(branch)-snapshot"
  }

  func image(os: String) -> String {
    self.resolved.hasPrefix("nightly-")
      ? "swiftlang/swift:\(self.resolved)-\(os)"
      : "swift:\(self.resolved)-\(os)"
  }

  /// A Windows container shares the host's kernel, so an image built for another Windows
  /// release does not start on it. The runner label is checked when the configuration is read.
  var windowsImage: String { self.image(os: "windowsservercore-ltsc2022") }
}

// MARK: - Versions

struct SwiftVersion: Comparable {
  private let components: [Int]

  init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return nil }
    let numbers = parts.compactMap { Int($0) }
    guard numbers.count == parts.count else { return nil }
    self.components = numbers + Array(repeating: 0, count: 3 - numbers.count)
  }

  static func < (first: SwiftVersion, second: SwiftVersion) -> Bool {
    first.components.lexicographicallyPrecedes(second.components)
  }

  /// A version list entry, which is a number or a nightly label and nothing else. A label
  /// this cannot order would otherwise be silently kept or dropped.
  static func inVersionList(_ label: String) -> SwiftVersion {
    guard let version = SwiftVersion(label) else {
      fatal(
        """
        Cannot compare '\(label)' as a version. A Swift version list takes numbers like 6.3, or a \
        nightly- label; '\(label)' is neither.
        """
      )
    }
    return version
  }
}

/// The oldest toolchain the package builds on. A version below it cannot resolve the
/// manifest, so a job on it fails for a reason the caller did not ask about.
struct MinimumVersion {
  /// As the caller or the manifest wrote it, for the message.
  let text: String
  private let floor: SwiftVersion?

  init(_ text: String) {
    self.text = text
    if text.isEmpty || text == "none" {
      self.floor = nil
      return
    }
    guard let version = SwiftVersion(text) else {
      fatal(
        """
        Cannot compare '\(text)' as a version: minimum_swift_version must be a number like 6.3, 'none', \
        or empty.
        """
      )
    }
    self.floor = version
  }

  /// A nightly is always kept: it is not a released version this can order.
  func admits(_ label: String) -> Bool {
    guard let floor = self.floor else { return true }
    if label.hasPrefix("nightly-") { return true }
    return SwiftVersion.inVersionList(label) >= floor
  }

  /// What a caller does about it. The filter is not an input of its own, so a message naming
  /// only what was dropped leaves them looking for a knob that isn't there.
  static let remedy =
    "The minimum comes from the manifest's swift-tools-version unless minimum_swift_version "
    + "overrides it, so raise the versions, or lower minimum_swift_version — 'none' turns the "
    + "filter off."
}

/// Falls back to the last entry when a list is all nightlies.
func newestRelease(in versions: [String]) -> String {
  let releases = versions.filter { !$0.hasPrefix("nightly-") }
  guard let newest = releases.max(by: { SwiftVersion.inVersionList($0) < SwiftVersion.inVersionList($1) }) else {
    return versions.last ?? ""
  }
  return newest
}

func toolsVersion(ofManifestAt path: String) -> String? {
  guard FileManager.default.fileExists(atPath: path) else { return nil }
  let contents: String
  do {
    contents = try String(contentsOfFile: path, encoding: .utf8)
  } catch {
    fatal("Could not read \(path): \(error)")
  }
  var line = contents.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
  guard line.hasPrefix("//") else { return nil }
  line = line.dropFirst(2).drop(while: { $0 == " " })
  guard line.hasPrefix("swift-tools-version:") else { return nil }
  let version = line.dropFirst("swift-tools-version:".count).drop(while: { $0 == " " })
    .prefix { $0.isNumber || $0 == "." }
  return version.isEmpty ? nil : String(version)
}

/// The lowest tools version the manifests declare, which is the oldest toolchain the package
/// claims to build on.
func detectMinimumVersion(includingSubdirectories: Bool) -> String {
  let fileManager = FileManager.default

  func manifests(in directory: String) -> [String] {
    let contents = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
    let versioned = contents.filter { $0.hasPrefix("Package@swift-") && $0.hasSuffix(".swift") }.sorted()
    return (["Package.swift"] + versioned).map { directory == "." ? $0 : "\(directory)/\($0)" }
  }

  var directories = ["."]
  if includingSubdirectories {
    let contents = (try? fileManager.contentsOfDirectory(atPath: ".")) ?? []
    directories += contents.filter { entry in
      var isDirectory: ObjCBool = false
      return fileManager.fileExists(atPath: entry, isDirectory: &isDirectory) && isDirectory.boolValue
    }.sorted().map { "./\($0)" }
  }

  var minimum: (version: SwiftVersion, text: String)?
  for path in directories.flatMap(manifests(in:)) {
    guard let declared = toolsVersion(ofManifestAt: path) else { continue }
    log("Found \(path) with tools-version: \(declared)")
    let version = SwiftVersion.inVersionList(declared)
    if let current = minimum, current.version <= version { continue }
    minimum = (version, declared)
  }
  return minimum?.text ?? ""
}

// MARK: - Commands

/// What a `*_command` input names: one command, or a map of label to command.
///
///   linux_command: swift test
///
///   linux_command: |
///     test: swift test
///     release:
///       command: swift build -c release
///       versions: ["6.3"]
struct Commands: InputDecodable, ExpressibleByStringLiteral {
  struct Command {
    var label: String
    var command: String
    var swiftVersions: [String]?

    /// The versions this variant runs on, in the group's own order rather than the label's.
    func versions(among available: [String]) -> [String] {
      guard let swiftVersions = self.swiftVersions else { return available }
      return available.filter(swiftVersions.contains)
    }
  }

  private var commands: [Command]

  /// The label leading an entry's job name, which is nothing when the group runs one command:
  /// entry names are required status checks in adopting repositories.
  func nameLabel(for variant: Command) -> String? {
    self.count > 1 ? variant.label : nil
  }

  init(_ command: String) {
    self.commands = [Command(label: "", command: command, swiftVersions: nil)]
  }

  init(stringLiteral command: String) {
    self.init(command)
  }

  /// The parse only classifies. Anything but a map of labels is the command itself, taken
  /// byte for byte — including a value that is not YAML at all, such as
  /// `[ -f x ] && swift build`.
  ///
  /// A shell command can parse as a map: `swift test --filter Foo: Bar` yields one keyed on
  /// everything before the colon. Requiring every key to be a label leaves only
  /// `<word>: <rest>` ambiguous, and that names a program whose name ends in a colon.
  init(input text: String, name: String) {
    self.commands = Commands.labeled(text, name: name) ?? [Command(label: "", command: text, swiftVersions: nil)]
  }

  /// The variants a map of labels names, or nil when the value is the command itself.
  private static func labeled(_ text: String, name: String) -> [Command]? {
    guard let parsed = parse(text) else { return nil }
    if parsed.isList {
      fatal(
        """
        \(name) takes a command, or a map of label to command such as {test: swift test}, but got a \
        list: \(text)
        """
      )
    }
    let members = parsed.mapMembers
    if members.isEmpty || members.contains(where: { !Commands.isLabel($0.key) }) { return nil }
    // A label written twice would run one command of the two the caller named, and under the
    // bare name, since one command earns no suffix.
    guard Set(members.map(\.key)).count == members.count else {
      fatal("\(name) names a label more than once: \(text)")
    }

    // A label carrying anything else — a number, a misspelled key, a blank command, an empty
    // version list — would leave the job running the group's default command under a name
    // that says otherwise, or produce no job for that label at all.
    let malformed = members.filter { settings(of: $0.value) == nil }
    guard malformed.isEmpty else {
      let reported = malformed.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
      fatal(
        """
        \(name) takes each label's command as a non-blank string, or a map of command and a non-empty \
        versions list, but got: \(reported)
        """
      )
    }
    return members.map { member in
      let settings = settings(of: member.value) ?? (command: "", versions: nil)
      return Command(label: member.key, command: settings.command, swiftVersions: settings.versions)
    }
  }

  /// The command and versions a label carries, or nil when it carries neither.
  private static func settings(of value: JSONValue) -> (command: String, versions: [String]?)? {
    if let command = value.asString {
      return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (command, nil)
    }
    guard case .object(let settings) = value,
      Set(settings.keys).subtracting(["command", "versions"]).isEmpty,
      let command = settings["command"]?.asString,
      !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    guard let listed = settings["versions"]?.nonNull else { return (command, nil) }
    guard let versions = listed.asArray, versions.isEmpty == false,
      versions.allSatisfy({ $0.asString != nil })
    else {
      return nil
    }
    return (command, versions.map(\.text))
  }

  /// A label leads the job name, so it is a word. That is also what keeps a shell command
  /// YAML reads as a map from being mistaken for one.
  private static func isLabel(_ text: String) -> Bool {
    guard let first = text.first, first.isASCII, first.isLetter || first.isNumber else { return false }
    return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
  }
}

// MARK: - Version overrides

/// One command each, and never none: a value that is not a map of labels is itself the
/// command, so there is always something to run.
extension Commands: RandomAccessCollection {
  var startIndex: Int { self.commands.startIndex }
  var endIndex: Int { self.commands.endIndex }
  subscript(position: Int) -> Command { self.commands[position] }
}

/// What a `*_version_overrides` input carries: for one version, arguments to add, or a
/// command to replace.
///
///   linux_version_overrides: |
///     6.2: -Xswiftc -warnings-as-errors
///     nightly-main:
///       command: swift build
///       arguments: --explicit-target-dependency-import-check error
struct VersionOverrides: InputDecodable {
  /// The input these were read from, which a message names so the caller knows which knob to
  /// turn. Empty for the default, which carries no overrides for a message to be about.
  private(set) var name = ""
  private var overrides: [(version: String, arguments: String, command: String)] = []

  var isEmpty: Bool { self.overrides.isEmpty }
  var versions: [String] { self.overrides.map(\.version) }

  init() {}

  func arguments(for version: String) -> String {
    self.overrides.last { $0.version == version }?.arguments ?? ""
  }

  func command(for version: String) -> String {
    self.overrides.last { $0.version == version }?.command ?? ""
  }

  /// The versions this replaces the command for, of those a group runs. A key naming a version
  /// the group's own list does not hold reaches none of its entries.
  func versionsReplacingTheCommand(among groupVersions: [String]) -> [String] {
    self.overrides.filter { !$0.command.isEmpty && groupVersions.contains($0.version) }.map(\.version)
  }

  /// The override for a version is read by looking the version up, so a value of any other
  /// shape is absent rather than wrong: the arguments the caller asked for go missing from a
  /// job that still passes, which is how a repository loses warnings-as-errors.
  init(input text: String, name: String) {
    self.name = name
    guard let parsed = parse(text) else {
      fatal("\(name) is not valid JSON or YAML: \(text)")
    }
    // A value that carried nothing — blank, or an explicit null — is no overrides rather
    // than a malformed map.
    if parsed.value.isNull { return }
    guard parsed.isMap else {
      fatal(
        """
        \(name) must be a map of version to override, such as {"6.3": "-Xswiftc -warnings-as-errors"}, \
        but got: \(text)
        """
      )
    }

    let members = parsed.mapMembers
    let notOverrides = members.filter {
      if case .object = $0.value { return false }
      return $0.value.asString == nil
    }
    guard notOverrides.isEmpty else {
      let reported = notOverrides.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
      fatal("\(name) takes the arguments as a string, or a map with command and arguments, but got: \(reported)")
    }

    // A misspelled key inside the map, or a value that is not a string, carries nothing while
    // looking as though it does.
    let malformed = members.filter { member in
      guard case .object(let settings) = member.value else { return false }
      return !Set(settings.keys).subtracting(["arguments", "command"]).isEmpty
        || settings.values.contains { $0.asString == nil }
    }
    guard malformed.isEmpty else {
      let reported = malformed.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
      fatal("\(name) takes command and arguments, each a string, but got: \(reported)")
    }

    self.overrides = members.map { member in
      (
        version: member.key,
        arguments: member.value.asString ?? member.value["arguments"]?.asString ?? "",
        command: member.value["command"]?.asString ?? ""
      )
    }
  }

  /// Fails when a key names no version any enabled group runs. The arguments it carries are
  /// silently lost otherwise, which is how a version rename drops warnings-as-errors.
  func validateKeys(against runnableVersions: [String]) {
    if self.isEmpty { return }
    // No versions means no enabled group reads these, so a key names nothing because nothing
    // runs. Failing there would take down the platforms that are enabled.
    if runnableVersions.isEmpty {
      log("WARNING: ignoring \(self.name): no enabled job group reads it")
      return
    }
    for key in self.versions where !runnableVersions.contains(key) {
      fatal(
        """
        \(self.name) override key '\(key)' does not match any version in the matrix. Valid keys: \
        \(runnableVersions.joined(separator: " "))
        """
      )
    }
  }
}

// MARK: - Inputs

/// An input. A value that carries nothing — unset, or the empty string Actions passes for an
/// input a caller left out — takes the declared default, which is already the parsed form.
@propertyWrapper
struct Input<Value: InputDecodable> {
  var wrappedValue: Value

  init(wrappedValue defaultValue: Value, _ variable: String) {
    self.wrappedValue = read(variable, default: defaultValue)
  }
}

func read<Value: InputDecodable>(_ variable: String, default defaultValue: Value) -> Value {
  let text = ProcessInfo.processInfo.environment[variable] ?? ""
  return text.isEmpty ? defaultValue : Value(input: text, name: variable.lowercased())
}

/// A value an input can carry. The conformance is where that shape's rules live: an input
/// carrying the wrong shape fails the run rather than contributing nothing.
protocol InputDecodable {
  init(input text: String, name: String)
}

/// An element of a list input.
protocol InputElement {
  /// - Parameters:
  ///   - element: the element as it parsed.
  ///   - text: the element as it was written, which is not the same for a number.
  init(element: JSONValue, text: String)
}

extension String: InputDecodable, InputElement {
  init(input text: String, name: String) { self = text }
  init(element: JSONValue, text: String) { self = text }
}

extension Bool: InputDecodable {
  /// Anything but `true` is off, which is what an unset input is.
  init(input text: String, name: String) { self = text == "true" }
}

extension Array: InputDecodable where Element: InputElement {
  /// A value of another shape would contribute no entries: the platform would be absent from
  /// a run that still reports success.
  init(input text: String, name: String) {
    guard let parsed = parse(text) else {
      fatal("\(name) is not valid JSON or YAML: \(text)")
    }
    guard let items = parsed.value.asArray else {
      fatal("\(name) must be a list, such as [\"a\", \"b\"], but got: \(text)")
    }
    self = zip(items, parsed.listElements).map(Element.init(element:text:))
  }
}

extension JSONValue: InputDecodable {
  /// An input passed through to the entry, such as an environment block.
  init(input text: String, name: String) {
    guard let parsed = parse(text) else {
      fatal("\(name) is not valid JSON or YAML: \(text)")
    }
    guard parsed.isMap || parsed.value.isNull else {
      fatal("\(name) must be a map of name to value, such as {FOO: bar}, but got: \(text)")
    }
    self = parsed.value.isNull ? .object([:]) : parsed.value
  }
}

/// One Swift SDK build's inputs, which all share its prefix.
struct SDKInputs {
  let prefix: String
  var enabled: Bool
  var versions: [String]
  var commands: Commands
  var setupCommand: String

  /// A Swift SDK build, whose enable is `enable_<prefix>_build`.
  init(prefix: String) {
    self.prefix = prefix
    let variable = prefix.uppercased()
    self.enabled = read("ENABLE_\(variable)_BUILD", default: false)
    self.versions = read("\(variable)_VERSIONS", default: Configuration.defaultSDKVersions)
    self.commands = read("\(variable)_COMMAND", default: "swift build")
    self.setupCommand = read("\(variable)_SETUP_COMMAND", default: "")
  }
}

/// An input naming one OS, or a list of them.
///
/// Only a list is taken from the parse: a single value is used exactly as it was written,
/// because YAML reads `24.10` as the number 24.1 and drops everything after a ` #`, and no
/// image is tagged 6.3-24.1.
struct OSList: InputDecodable, ExpressibleByStringLiteral {
  var names: [String]
  /// A list of Linux distributions names container images, so even a list of one runs in a
  /// container.
  var wasList: Bool

  init(stringLiteral name: String) {
    self.names = [name]
    self.wasList = false
  }

  init(input text: String, name: String) {
    guard let parsed = parse(text) else {
      fatal("\(name) is not valid JSON or YAML: \(text)")
    }
    if parsed.isList {
      self.names = [String](input: text, name: name)
      self.wasList = true
    } else if parsed.isMap {
      fatal("\(name) must be a name or a list of them, such as [\"a\", \"b\"], but got: \(text)")
    } else {
      self.names = [text]
      self.wasList = false
    }
  }
}

/// A macOS entry driven by a swiftly-managed toolchain rather than the Xcode that ships one.
struct SwiftlyToolchain: InputElement {
  var xcodeVersion = ""
  var swiftlyToolchain = ""
  /// An entry naming its own OS runs there alone; the rest fan out over macos_os.
  var osVersion: String?
  var architecture: String?

  init(xcodeVersion: String, swiftlyToolchain: String) {
    self.xcodeVersion = xcodeVersion
    self.swiftlyToolchain = swiftlyToolchain
  }

  init(element: JSONValue, text: String) {
    let known = ["xcode_version", "swiftly_toolchain", "os_version", "arch"]
    let unknown = Set(element.asObject?.keys ?? [:].keys).subtracting(known).sorted()
    if !unknown.isEmpty {
      fatal(
        """
        macos_swiftly_toolchains includes unknown keys: \(unknown.joined(separator: ", ")). \
        An entry takes xcode_version, swiftly_toolchain, os_version and arch.
        """
      )
    }
    self.xcodeVersion = element["xcode_version"]?.text ?? ""
    self.swiftlyToolchain = element["swiftly_toolchain"]?.text ?? ""
    self.osVersion = element["os_version"]?.text
    self.architecture = element["arch"]?.text
  }
}

// MARK: - JSON

/// A value of any shape, which is what an input carries before it is known to be one.
enum JSONValue: Codable {
  case null
  case bool(Bool)
  case integer(Int)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    // Each `try?` asks "is it this shape", so a failure is the answer rather than an error
    // to swallow. The order is the one JSON allows: an integer also decodes as a double.
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let items): try container.encode(items)
    case .object(let members): try container.encode(members)
    }
  }

  subscript(key: String) -> JSONValue? {
    guard case .object(let members) = self else { return nil }
    return members[key]
  }

  var asObject: [String: JSONValue]? {
    guard case .object(let members) = self else { return nil }
    return members
  }

  var asString: String? {
    guard case .string(let text) = self else { return nil }
    return text
  }

  var asBool: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  var asArray: [JSONValue]? {
    guard case .array(let items) = self else { return nil }
    return items
  }

  /// The value, or nil when it carried nothing: an absent setting and an explicit null are
  /// the same answer.
  var nonNull: JSONValue? { self.isNull ? nil : self }

  var isNull: Bool {
    guard case .null = self else { return false }
    return true
  }

  /// The value as one line of text, the way `jq -r` writes it. A version list written
  /// `[6.3]` still names the version `6.3`.
  var text: String {
    self.asString ?? self.description
  }
}

extension JSONValue: CustomStringConvertible {
  /// The value as JSON on one line, which is how a message quotes back what a caller wrote.
  var description: String {
    switch self {
    case .null: return "null"
    case .bool(let value): return value ? "true" : "false"
    case .integer(let value): return String(value)
    case .number(let value): return String(value)
    case .string(let text): return JSONValue.quoted(text)
    case .array(let items): return "[" + items.map(\.description).joined(separator: ",") + "]"
    case .object(let members):
      // Sorted so a message quoting a caller's value back reads the same on every run: a
      // dictionary has no order of its own.
      let written = members.sorted { $0.key < $1.key }
      return "{" + written.map { "\(JSONValue.quoted($0.key)):\($0.value)" }.joined(separator: ",") + "}"
    }
  }

  static func quoted(_ text: String) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result + "\""
  }
}

// MARK: - Reading a value with yq

/// A value as yq read it: its YAML tag, and — for a map — its members in the order they were
/// written, a key written twice included.
struct Parsed: Decodable {
  var tag: String
  var value: JSONValue
  /// One element holding the members when the value is a map, and empty otherwise: yq has no
  /// conditional that returns either. `mapMembers` is what a caller reads.
  var members: [[Member]]
  /// The same, for a list's elements as they were written.
  var elements: [[String]]

  struct Member: Decodable {
    var key: String
    var value: JSONValue
  }

  var isList: Bool { self.tag == "!!seq" }
  var isMap: Bool { self.tag == "!!map" }
  var isCollection: Bool { self.isList || self.isMap }
  var mapMembers: [Member] { self.members.first ?? [] }
  /// A list's elements as text. YAML reads `24.10` as the number 24.1, and no image is tagged
  /// 6.3-24.1, so the token the caller wrote is what a name is taken from.
  var listElements: [String] { self.elements.first ?? [] }
}

/// A value's shape, its members and its elements in one pass. `tostring` is applied to a
/// map's keys and a list's elements, and to nothing else: `versions: [6.3]` has to stay a
/// number for the label check to reject it.
private let parseFilter = """
  {"tag": tag, "value": ., \
  "members": [select(tag == "!!map") | to_entries | map({"key": (.key | tostring), "value": .value})], \
  "elements": [select(tag == "!!seq") | map(tostring)]}
  """

/// Reads a value the way the shell script's yq call did. Nil is a value that is neither
/// YAML nor JSON, which two callers tell apart from a value of the wrong shape.
func parse(_ text: String) -> Parsed? {
  let result = run(yq, ["-o=json", "-I=0", parseFilter], input: text)
  guard result.worked else { return nil }
  do {
    return try JSONDecoder().decode(Parsed.self, from: result.output)
  } catch {
    fatal("yq produced JSON this generator could not read: \(error)")
  }
}

// MARK: - Running jq and yq

func lookup(executable: String) -> URL {
  #if os(Windows)
  let pathSeparator: Character = ";"
  let executable = executable + ".exe"
  #else
  let pathSeparator: Character = ":"
  #endif
  for variable in ["PATH", "Path"] {
    let paths = ProcessInfo.processInfo.environment[variable] ?? ""
    for directory in paths.split(separator: pathSeparator) {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executable)
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
  }
  fatal("\(executable) not found on PATH")
}

let jq = lookup(executable: "jq")
let yq = lookup(executable: "yq")

func run(_ tool: URL, _ arguments: [String], input: String) -> (output: Data, diagnostic: String, worked: Bool) {
  let process = Process()
  process.executableURL = tool
  process.arguments = arguments
  let standardInput = Pipe()
  let standardOutput = Pipe()
  let standardError = Pipe()
  process.standardInput = standardInput
  process.standardOutput = standardOutput
  process.standardError = standardError

  do {
    try process.run()
  } catch {
    fatal("Could not run \(tool.path): \(error)")
  }

  // The value goes in on another thread: a matrix larger than the pipe's buffer would
  // otherwise fill it while nothing is reading the other end yet.
  DispatchQueue.global().async {
    standardInput.fileHandleForWriting.write(Data(input.utf8))
    standardInput.fileHandleForWriting.closeFile()
  }
  // Both streams are drained at once, for the same reason: whichever went unread could fill
  // and stall the tool while this waits on the other.
  //
  // nonisolated(unsafe) because the write happens before the group's wait returns, which the
  // compiler cannot see.
  nonisolated(unsafe) var diagnostic = Data()
  let draining = DispatchGroup()
  DispatchQueue.global().async(group: draining) {
    diagnostic = standardError.fileHandleForReading.readDataToEndOfFile()
  }
  let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
  draining.wait()
  process.waitUntilExit()

  return (output, String(decoding: diagnostic, as: UTF8.self), process.terminationStatus == 0)
}

func format(_ matrix: Data, with tool: URL, _ arguments: [String]) -> String {
  let result = run(tool, arguments, input: String(decoding: matrix, as: UTF8.self))
  guard result.worked else {
    fatal("\(tool.lastPathComponent) could not format the matrix: \(result.diagnostic)")
  }
  return String(decoding: result.output, as: UTF8.self)
}

// MARK: - Diagnostics

/// Diagnostics go to standard error; standard output carries the matrix.
func log(_ message: String) {
  FileHandle.standardError.write(Data("** \(message)\n".utf8))
}

/// Reports a configuration that would produce a matrix without the jobs the caller asked
/// for, and stops. A green run missing those jobs is what every one of these prevents.
func fatal(_ message: String) -> Never {
  FileHandle.standardError.write(Data("** ERROR: \(message)\n".utf8))
  exit(1)
}

// MARK: - Running

let generator = Generator(Configuration())
generator.write(generator.generate())
