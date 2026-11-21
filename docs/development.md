# Development

## Setup

Install Xcode, select its command-line tools, and install an iPhone simulator runtime when simulator tests are required. Use Swift 6 and install the iOS, macOS, watchOS, tvOS and visionOS SDKs. Minimum OS versions are iOS/iPadOS 18, macOS 15, watchOS 11, tvOS 18 and visionOS 2. Bootstrap downloads checksum-pinned XcodeGen 2.46.0 and actionlint 1.7.12 into ignored `.tools/`; Homebrew is not required.

```sh
./scripts/bootstrap.sh
open Munie.xcodeproj
```

`project.yml` is authoritative; regenerate after configuration changes. Do not hand-edit or commit the generated `Munie.xcodeproj`. Choose a unique bundle identifier and your signing team for real devices. Simulator/generic builds do not require production signing credentials.

In Xcode, choose `MunieRemodex` for the primary iPhone product. The retained `Munie` checkpoint supports native iPhone, iPad, Mac, Apple TV and Apple Vision Pro destinations; its `MunieHost` scheme builds the earlier Mac companion. Choose `MunieWatch` for the standalone local Watch app. iPadOS shares the retained iOS target and device family; Mac uses native macOS, without Catalyst. No device sync or Watch connectivity is implied. tvOS cache may be purged. Platform interaction and distribution gates are in the [acceptance matrix](standards/platform-acceptance.md).

## Primary adopted iPhone target

Use `MunieRemodex` for the primary iPhone client and `MunieDesktop` for the native Mac companion. Munie follows Codex's existing Mac settings; its UI grants the project and confirms nearby pairing without a separate login or provider setup. Terminal commands here are developer tooling only. Runtime source pins, original notices and distribution limits are in [desktop runtime](../references/desktop-product-runtime.md); `Munie`, `MunieHost` and their tests remain the earlier checkpoint.

Build a complete local Mac app resource bundle with `python3 scripts/prepare-desktop-runtime.py`, then build `MunieDesktop`. The tool verifies fixed Node/Codex archives, uses the npm cache with lifecycle scripts disabled, and writes fresh `build/DesktopBundle/{Runtime,Host}`; run `scripts/setup-remodex.sh` first to populate the locked bridge/relay cache when needed. Offline archive inputs are supported. Choose a fresh output and set `MUNIE_DESKTOP_BUNDLE` when retaining another bundle. Generated binaries/resources remain ignored. Intel packaging and distribution signing are not yet accepted. For compiler/unit-only CI, set `MUNIE_DESKTOP_COMPILE_ONLY=YES`; this intentionally produces no usable execution app and cannot be archived.

`scripts/run-remodex-local.sh` remains an advanced developer/acceptance launcher. It accepts an explicit native executable, project, private state/account directory and authenticated relay route. It does not form part of ordinary user onboarding. Existing private Tailscale Serve tests remain useful as remote-network evidence; the new nearby flow does not silently configure that external service.

`config/Remodex.Package.resolved` is copied into the generated project at bootstrap. All builds use `-onlyUsePackageVersionsFromResolvedFile`; update the reviewed lock and dependency notices together. Simulator execution uses ad-hoc signing because actual Security/Keychain tests require entitlements. Device builds use the existing ignored signing configuration. Imported Swift keeps upstream language mode and formatting; the [source manifest](../references/licenses/remodex-source-manifest.json) is the precise exception scope. New Swift files still pass strict formatting.

The existing upstream UI literals detected by the repository checker are enumerated per source path in [localization debt](../references/licenses/remodex-localization-debt.json). This is a migration exception, never bilingual acceptance. New literals in the same source files and all new catalog entries remain subject to English/Simplified Chinese checks. The full upstream UI and its voice policy still require migration against the unchanged product requirements.

## Daily workflow

```sh
# Run from the primary Munie checkout.
git fetch origin
mkdir -p .munie-local/worktrees
git worktree add --no-track -b feat_capture_search .munie-local/worktrees/feat_capture_search origin/dev
```

Work inside the new checkout, keep its scope focused, and run the relevant checks before a PR to `dev`. Each worktree needs its own generated Xcode project and local build products. Shared branch history does not share uncommitted files. Use `git worktree list` to inspect checkouts.

```sh
./scripts/check.sh
./scripts/test-ios.sh
```

`check.sh` runs source-adoption, repository/localization checks, Swift formatting, core/host/nearby tests with coverage, the Release submission crash experiment, actionlint, core smoke, Release performance budgets and all eleven Apple Debug/Release builds. It assembles fresh verified Mac resources, executes `test-desktop.sh` app-hosted lifecycle tests, and runs the bridge/relay Node tests. `test-remodex-ios.sh` executes the adopted offline unit suite, deterministic timeline smoke and three-page nearby onboarding in English/Simplified Chinese through isolated DEBUG routes. The onboarding fixture disables radio discovery; it is not nearby device acceptance. `test-ios.sh` retains the native checkpoint suite and selects an available iPhone simulator; set `IOS_TEST_DESTINATION` for an explicit Xcode destination. UI tests and iOS execution of the app tests need a simulator; presentation tests also run on macOS. See [testing](testing.md) for commands and precise evidence requirements. Keep outputs and caches in ignored paths. References are optional local checkouts managed by the registry workflow; they are not runtime dependencies.

Review subagent work as normal code: path ownership, API agreement, diff review, relevant tests, then integration. Update status and decisions with the final implementation. Release changes go from `dev` to `main` by PR; no routine feature development on `main`.

## Local signing and host tests

Bootstrap creates ignored `config/Signing.xcconfig` from the tracked example. Set `PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` there for a device build. Override `MUNIE_WATCH_BUNDLE_IDENTIFIER` there for the independent Watch app; it has its own placeholder identity. The initial ID is a placeholder; no domain or Apple registration is claimed. Do not edit the generated project to store lasting configuration. Release secrets override the placeholder in CI.

The root `Package.swift` compiles the shared presentation model/tests and the Mac-only submission ledger, bounded native Codex adapter and diagnostic executables. Shipping Apple app targets remain defined in `project.yml` with iOS using MunieRemote and the Mac companion linking product/transport/execution modules. Run `swift test` for presentation and ledger behavior without an iPhone runtime; use the [submission experiment](testing.md#host-submission-authorization-and-crash-windows) for bounded synthetic process-kill recovery. The [native integration experiment](testing.md#ledger-integrated-native-codex-experiment) is opt-in and additionally needs an explicitly selected fixed Codex binary/schema; ordinary CI uses offline fixtures. The product service and opt-in actual-account/phone acceptance commands are described in [testing](testing.md#opt-in-actual-codex-product-acceptance); research executables remain separate.

## Available-device testing

The owner prefers automatic device selection for development: use a reachable, unlocked physical iPhone when available; use a compatible iPhone simulator when the phone is away, unreachable or locked. On a later run, recheck availability and return to the physical phone. `python3 scripts/test-available-ios.py --dry-run` reports selection; without `--dry-run` it runs bounded existing test entry points and records the actual path. Real-device signing failures remain failures, with original logs; a simulator pass cannot replace that result. This selection does not authorize deleting apps, changing device settings, recording audio or new real-model usage. Model/account acceptance stays separately opt-in.

The configured Munie maintenance heartbeat applies the same preference on scheduled runs; it is not a continuous device-presence listener. Executing background checks requires the app/scheduler and Mac to be available. Current schedule and last actual execution are separate facts.
