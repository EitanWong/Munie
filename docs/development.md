# Development

## Setup

Install Xcode, select its command-line tools, and install an iPhone simulator runtime when simulator tests are required. Use Swift 6 and iOS 18+ SDKs. Bootstrap downloads checksum-pinned XcodeGen 2.46.0 and actionlint 1.7.12 into ignored `.tools/`; Homebrew is not required.

```sh
./scripts/bootstrap.sh
open Munie.xcodeproj
```

`project.yml` is authoritative; regenerate after configuration changes. Do not hand-edit or commit the generated `Munie.xcodeproj`. Choose a unique bundle identifier and your signing team for real devices. Simulator/generic builds do not require production signing credentials.

## Daily workflow

```sh
git switch dev
git worktree add ../.munie-worktrees/feat_capture_search -b feat_capture_search dev
```

Work inside the new checkout, keep its scope focused, and run the relevant checks before a PR to `dev`. Each worktree needs its own generated Xcode project and local build products. Shared branch history does not share uncommitted files. Use `git worktree list` to inspect checkouts.

```sh
./scripts/check.sh
./scripts/test-ios.sh
```

`check.sh` runs repository/localization checks, Swift formatting, core and host presentation tests with coverage, actionlint, core smoke and a generic iOS build including test bundles. `test-ios.sh` selects an available iPhone simulator; set `IOS_TEST_DESTINATION` for an explicit Xcode destination. UI tests and iOS execution of the app tests need a simulator; presentation tests also run on macOS. See [testing](testing.md) for commands and precise evidence requirements. Keep outputs and caches in ignored paths. References are optional local checkouts managed by the registry workflow; they are not runtime dependencies.

Review subagent work as normal code: path ownership, API agreement, diff review, relevant tests, then integration. Update status and decisions with the final implementation. Release changes go from `dev` to `main` by PR; no routine feature development on `main`.

## Local signing and host tests

Bootstrap creates ignored `config/Signing.xcconfig` from the tracked example. Set `PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` there for a device build. The initial ID is a placeholder; no domain or Apple registration is claimed. Do not edit the generated project to store lasting configuration. Release secrets override the placeholder in CI.

The root `Package.swift` is a host test harness that compiles the same presentation model and test sources on macOS. It does not introduce a second shipping app or runtime package. Run `swift test` to test presentation behavior without an iPhone runtime.
