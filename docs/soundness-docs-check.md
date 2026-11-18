# Documentation Check

The Soundness workflow can verify that your Swift package's [DocC](https://www.swift.org/documentation/docc/) documentation builds without warnings. Two checks are available:

- **Documentation check** — runs on Linux. Enabled by default.
- **Documentation check (macOS)** — runs on a self-hosted macOS runner. Opt-in.

Running both lets you catch documentation issues that only surface on one toolchain. Either check can also run once per Swift version, to catch a regression in a new toolchain before it reaches a release; see [Running across Swift versions](#running-across-swift-versions).

Documentation warnings (and, by default, DocC analyzer findings) cause the job to fail.

## Requirements

### For both jobs

1. **A `Package.swift`** (or any `Package*.swift`) at the repository root.

2. **At least one documentation target**, supplied via either:
   - a `documentation_targets` entry in a `.spi.yml` file at the repository root.
   - the `docs_check_targets` / `docs_check_macos_targets` input, **or**

   If neither is provided, the job exits successfully without checking anything.

The `.spi.yml` file is also where you can declare per-target DocC parameters via `custom_documentation_parameters`. Read the [official documentation](https://swiftpackageindex.com/SwiftPackageIndex/SPIManifest/1.12.0/documentation/spimanifest/commonusecases) for the full schema. For example:

```yaml
version: 1
builder:
  configs:
    - documentation_targets: [MyLibrary, MyOtherLibrary]
      custom_documentation_parameters:
        - --include-extended-types
```

Target names must match real SwiftPM target names declared in `Package.swift`.

You do not need to add `swift-docc-plugin` to your package — CI provides it for you.

### Additional requirement for the macOS job

A self-hosted runner must be registered with the label set `[self-hosted, macos, <version>, <arch>]` matching the values you pass to `docs_check_macos_version` and `docs_check_macos_arch`.

Xcode must be installed in `/Applications` as `Xcode_<version>.app`, where the version is `docs_check_macos_xcode_version`, for example `Xcode_26.0.app`. When you give `docs_check_macos_swift_versions`, each Swift version needs `Xcode_swift_<version>.app` instead, for example `Xcode_swift_6.4.app`.

## Enabling the check

Add (or extend) a workflow file under `.github/workflows/` in your repository:

```yaml
name: Pull request

on:
  pull_request:
    branches: [main]

jobs:
  soundness:
    name: Soundness
    uses: swiftlang/github-workflows/.github/workflows/soundness.yml@<to-be-updated>>
    with:
      docs_check_enabled: true
```

This enables the Linux documentation check along with the other soundness checks. The macOS variant remains off unless you opt in.

## Running across Swift versions

A DocC regression often shows up in a new toolchain before it reaches a release. To catch one early, run the check on a schedule across the Swift versions you care about. This workflow runs only the documentation checks, once for each version:

```yaml
name: Documentation on every Swift version

on:
  schedule:
    - cron: "0 6 * * *"

jobs:
  soundness:
    name: Soundness
    uses: swiftlang/github-workflows/.github/workflows/soundness.yml@main
    with:
      docs_check_linux_swift_versions: '["current-1", "current", "nightly-release", "nightly-main"]'
      docs_check_macos_enabled: true
      docs_check_macos_swift_versions: '["current"]'
      # Only the documentation checks run here.
      api_breakage_check_enabled: false
      unacceptable_language_check_enabled: false
      license_header_check_enabled: false
      broken_symlink_check_enabled: false
      format_check_enabled: false
      shell_check_enabled: false
      yamllint_check_enabled: false
      python_lint_check_enabled: false
```

Each version becomes its own job, named for the version: `Documentation check (Swift current)`, `Documentation check (Swift nightly-main)` and `Documentation check (macOS, Swift current)`.

A version is one of these:

- `current`, the release named by `swift_current_release`. `current-1` and `current-2` are the releases before it.
- `nightly-release`, the nightly for the branch named by `swift_nightly_release`.
- `nightly-main`, the nightly built from `main`.
- A version number such as `6.3`.

On Linux a release runs in `swift:<version>-noble` and a nightly in `swiftlang/swift:nightly-<branch>-noble`. On macOS a version runs on the runner's `Xcode_swift_<version>.app`. A nightly is rejected there, because a macOS nightly needs a swiftly toolchain and not an Xcode.

A list changes how the check behaves:

- It replaces the single check. While `docs_check_linux_swift_versions` is set, `docs_check_container_image` has no effect, and while `docs_check_macos_swift_versions` is set, `docs_check_macos_xcode_version` has none.
- `docs_check_enabled` and `docs_check_macos_enabled` still switch the checks on and off. `docs_check_macos_version` and `docs_check_macos_arch` still choose the runner.
- Versions older than the tools version of your `Package.swift` are left out. If that leaves none, the plan job fails and names the versions.
- Documentation targets, additional arguments, the analyzer setting and `linux_pre_build_command` apply to every version.
- Do not make the nightly jobs required checks. A nightly can break the check without any change on your side.

`swift_current_release` and `swift_nightly_release` default to `6.4` and `6.4.x`.

## Configuration

### Linux job (Documentation check)

| Input | Type | Default | Description |
|---|---|---|---|
| `docs_check_enabled` | boolean | `true` | Enable or disable the job. |
| `docs_check_container_image` | string | `swift:6.4-noble` | Docker image used to run the check. No effect while `docs_check_linux_swift_versions` is set. |
| `docs_check_linux_swift_versions` | string | `""` | JSON array of Swift versions, such as `'["current", "nightly-main"]'`. Runs the check once for each, in place of the one run in `docs_check_container_image`. |
| `docs_check_targets` | string | `""` | Space-separated list of documentation targets to check. When empty, targets are read from `.spi.yml` (if present). |
| `docs_check_additional_arguments` | string | `""` | Extra arguments to pass to DocC. |
| `docs_check_analyze` | boolean | `true` | Set to `false` to skip DocC's analyzer pass. |
| `linux_pre_build_command` | string | `""` | Shell command to run before the check (e.g., installing system dependencies). |

### macOS job (Documentation check (macOS))

| Input | Type | Default | Description |
|---|---|---|---|
| `docs_check_macos_enabled` | boolean | `false` | Enable or disable the job. |
| `docs_check_macos_version` | string | `goldengate` | macOS version label of the runner to target. |
| `docs_check_macos_arch` | string | `ARM64` | Architecture label of the runner to target. |
| `docs_check_macos_xcode_version` | string | `26.0` | Xcode version to use. No effect while `docs_check_macos_swift_versions` is set. |
| `docs_check_macos_swift_versions` | string | `""` | JSON array of Swift versions. Runs the check once for each, in place of the one run on `docs_check_macos_xcode_version`. A nightly is rejected. |
| `docs_check_macos_targets` | string | `""` | Space-separated list of documentation targets to check. When empty, targets are read from `.spi.yml` (if present). |
| `docs_check_macos_additional_arguments` | string | `""` | Extra arguments to pass to DocC. |
| `docs_check_macos_analyze` | boolean | `true` | Set to `false` to skip DocC's analyzer pass. |

The macOS job requires a self-hosted runner registered with the label set `[self-hosted, macos, <version>, <arch>]`.

## Common scenarios

### Enable the macOS check

```yaml
jobs:
  soundness:
    uses: swiftlang/github-workflows/.github/workflows/soundness.yml@main
    with:
      docs_check_macos_enabled: true
      docs_check_macos_version: "goldengate"
      docs_check_macos_arch: "ARM64"
      docs_check_macos_xcode_version: "26.0"
```

### Check only specific targets

By default the check documents every target listed in `.spi.yml`. To override that list without editing `.spi.yml`, provide the target names explicitly:

```yaml
jobs:
  soundness:
    uses: swiftlang/github-workflows/.github/workflows/soundness.yml@main
    with:
      docs_check_targets: "MyLibrary MyOtherLibrary"
```

### Pin a different Swift toolchain or pass extra DocC flags

```yaml
jobs:
  soundness:
    uses: swiftlang/github-workflows/.github/workflows/soundness.yml@main
    with:
      docs_check_container_image: "swift:nightly-noble"
      docs_check_additional_arguments: "--include-extended-types"
      linux_pre_build_command: "apt-get update && apt-get install -y libxml2-dev"
```

### Skip the DocC analyzer

```yaml
jobs:
  soundness:
    uses: swiftlang/github-workflows/.github/workflows/soundness.yml@main
    with:
      docs_check_analyze: false
```

### Disable the check

If you want to skip the documentation check entirely (regardless of whether your package has documentation targets), turn it off:

```yaml
jobs:
  soundness:
    uses: swiftlang/github-workflows/.github/workflows/soundness.yml@main
    with:
      docs_check_enabled: false
```

If you simply have no documentation targets to check, you can leave the job enabled — it will exit successfully without doing anything.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Job logs `No '.spi.yml' found, no documentation targets to check.` and exits successfully. | Neither `docs_check_targets` nor a `.spi.yml` was provided. Add one of them if you expected the check to run. |
| `Package.swift not found.` | The check expects a SwiftPM package at the repo root. |
| Warnings cause the job to fail. | Intentional. Resolve the DocC warnings, or pass DocC flags via `.spi.yml`'s `custom_documentation_parameters` to suppress them. |
| macOS job stays queued. | No self-hosted runner matches the requested labels. Verify the `version` and `arch` inputs against your runner inventory. |
| macOS job cannot find Xcode. | The app is not installed on the runner under the name the job looks for: `Xcode_<docs_check_macos_xcode_version>.app`, or `Xcode_swift_<version>.app` when you give `docs_check_macos_swift_versions`. |
| `Plan checks` fails with `cannot run on the macOS Swift version 'nightly-main'`. | macOS does not run nightlies. Remove it from `docs_check_macos_swift_versions`. |
| `Plan checks` fails with `removes every version`. | Every version in the list is older than the tools version of your `Package.swift`. Add a newer one. |
| `Plan checks` fails with `Cannot compare '<label>' as a version` or `must be a list`. | A label is not a version, or the list is not a JSON array. Write it as `'["current", "nightly-main"]'`. |
