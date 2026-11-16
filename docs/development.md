# Development

## Setup

Install Xcode, select its command-line tools, and install an iPhone simulator runtime when simulator tests are required. Use Swift 6 and iOS 18+ SDKs. Bootstrap downloads checksum-pinned XcodeGen 2.46.0 into ignored `.tools/`; Homebrew is not required.

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

`check.sh` runs repository/localization checks, Swift formatting, core tests with coverage, core smoke and a generic iOS build. `test-ios.sh` selects an available iPhone simulator; set `IOS_TEST_DESTINATION` for an explicit Xcode destination. iOS app tests need a simulator. See [testing](testing.md) for commands and precise evidence requirements. Keep outputs and caches in ignored paths. References are optional local checkouts managed by the registry workflow; they are not runtime dependencies.

Review subagent work as normal code: path ownership, API agreement, diff review, relevant tests, then integration. Update status and decisions with the final implementation. Release changes go from `dev` to `main` by PR; no routine feature development on `main`.
