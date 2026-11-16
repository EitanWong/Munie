# Testing

## Automated layers

| Layer | Purpose |
|---|---|
| Core unit/integration | Validation, Unicode/limits, persistence/reload, deletion, corrupt/versioned data, concurrency and failed writes |
| Core smoke | Real temporary-file save → reopen → delete loop through the public API |
| App tests | Presentation behavior with injected storage, including failures |
| UI smoke | Capture → observe saved item → retrieve → delete on an iPhone simulator |
| Build/static | Swift formatting, repository/localization checks and generated native builds for all five Apple SDK families |

Use tests to detect behavior regressions; avoid tests that merely repeat implementation or assert cosmetic trivia. Test data must be synthetic. Keep failed-write and corrupt-file evidence because data loss is a critical risk.

```sh
swift test --package-path packages/MunieCore
swift test # app presentation model on macOS
swift run --package-path packages/MunieCore MunieCoreSmoke
./scripts/check.sh
./scripts/test-ios.sh
```

`check.sh` runs static/repository/localization checks, core and host presentation tests with coverage, actionlint, the core smoke executable Release core performance budgets, generic Debug builds for iOS/iPadOS, macOS, tvOS, visionOS and watchOS (including the iOS test bundles), and an unsigned generic iOS device Release build. Each platform has a separate `build/*-build.log`. Run `./scripts/build-apple-platforms.sh` to repeat only generation and builds. `test-ios.sh` runs app unit tests and UI smoke tests on the newest available iPhone runtime compatible with the selected Xcode SDK, with explicit per-test time limits (120s default, 180s maximum). Simulator boot has a 240-second limit; the CI simulator step has a 15-minute upper limit. Four fixture tests cover runtime/device selection. Use `IOS_TEST_DESTINATION` to select an explicit destination.

Do not report a build as a UI test, or a simulator run as hardware validation. The integrator records actual outcomes in [project status](project-status.md), with tool versions and environment limits. Hosted workflows need an observed run after a GitHub remote is connected.

Repository checks inspect the generated Xcode graph (including the iPhone/iPad device family and separate watchOS target), the actual SwiftPM manifests and standard package source roots, localization and maintained documentation links. Fixture tests reject dropped platforms, missing source trees, invalid Watch embedding and hidden Release build failures. Documentation checks require topic filenames and index reachability, excluding code examples; semantic freshness still needs review. See [maintenance](maintenance.md).

## Device acceptance before beta

Run the same capture/save/relaunch/retrieve/delete loop on iPhone and iPad in English and Simplified Chinese. Review VoiceOver, Dynamic Type, keyboard handling, empty/error states and interrupted app lifecycle. Verify private file location, deletion semantics, device backup expectations and available disk failure behavior.

Apply the [Apple platform acceptance matrix](standards/platform-acceptance.md) to Mac, Watch, TV and Vision Pro as well. Native compilation is an engineering gate; focus/remote input, small-screen navigation, spatial input, accessibility, persistence limits, native artwork and signed distribution require their own evidence. tvOS uses purgeable cache, and no platform currently synchronizes records.

For future voice/remote work, extend only the relevant matrix: permissions revoked, locked/cold start, calls/audio interruptions, offline drafts, Wi-Fi↔cellular change, duplicate retry, cancellation, credentials revoked and host unavailable. Record literal inputs, state transitions and actual results. Same-LAN success does not establish outside-LAN operation.

No hardware, user-study, remote-task or distribution result is implied by the repository scaffold.

## Performance evidence

Run `./scripts/benchmark-core.sh` independently for the optimized synthetic store workload. Raw samples, provenance and budgets are defined only in the [performance standard](standards/performance.md). CI retains `build/core-performance*.json` and build logs; host measurements do not establish app search, real-device, voice or remote latency. Ordinary builds include `build/ios-release-build.log`; signing and distribution are still separate.

## Opt-in local Codex protocol experiment

After exporting and checking both schema bundles with the [Harness workflow](standards/harness-integration.md#codex-范围清单与漂移), select the actual native Mach-O executable, rather than an npm/shell launcher:

```sh
CODEX_NATIVE=/absolute/path/to/native/codex
python3 scripts/probe-codex.py --codex "$CODEX_NATIVE" \
  --schema-dir build/codex-schema-experimental \
  --default-schema-dir build/codex-schema-stable
```

This macOS-only research command requires the saved Codex 0.162.1 schema and an available `sandbox-exec`; it never installs Codex or falls back to an unrestricted run. It creates temporary data/config/workspace directories, passes a minimal child environment, denies real-home/Keychain reads, Keychain Mach-service access, writes outside its fixture and all network operations. Only the two system preferences IPC endpoints remain allowed so managed configuration is not silently replaced by defaults. Six guard checks run before Codex. Existing login/config/session files are not copied or modified.

The RPC sequence is fixed: pre-initialize nonexistent interrupt, initialize, initialized notification, duplicate initialize, invalid interrupt parameters, unknown method and nonexistent turn interrupt. No thread creation/resume, model turn, tool, approval, listener or real cancellation runs. Each response has a 10-second deadline, the transport has a 60-second deadline, lines are limited to 64 KiB and each output stream to 512 KiB. Initialization and the bounded shutdown both validate messages; unexpected server requests/notifications fail without a response. Cleanup closes stdin, escalates TERM/KILL and confirms process-group disappearance. This is a diagnostic transport, not a reusable production adapter.

The mode-600 `build/codex-protocol-probe.json` records the binary/runner/schema hashes, revision and dirty flag, sanitized checks, bounded stream hashes/counts and cleanup. It excludes raw server errors, paths, user agent, host/installation identifiers and stderr. A failed attempt writes a failed report rather than retaining an earlier pass. Offline fake-peer regressions run in ordinary repository checks without Codex, credentials or model/network access; they cannot establish upstream behavior. Real observations and their limits are recorded in [project status](project-status.md), with field and network evidence in [protocol research](../references/codex-protocol-research.md).
