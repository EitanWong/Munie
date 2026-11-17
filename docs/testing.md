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

`check.sh` runs static/repository/localization checks, core and host presentation/execution tests with coverage, actionlint, the host submission crash experiment, the core smoke executable, Release core performance budgets, generic Debug builds for iOS/iPadOS, macOS, tvOS, visionOS and watchOS (including the iOS test bundles), and an unsigned generic iOS device Release build. Each platform has a separate `build/*-build.log`. Run `./scripts/build-apple-platforms.sh` to repeat only generation and builds. `test-ios.sh` runs app unit tests and UI smoke tests on the newest available iPhone runtime compatible with the selected Xcode SDK, with explicit per-test time limits (120s default, 180s maximum). Simulator boot has a 240-second limit; the CI simulator step has a 15-minute upper limit. Four fixture tests cover runtime/device selection. Use `IOS_TEST_DESTINATION` to select an explicit destination.

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

The mode-600 `build/codex-protocol-probe.json` records the binary/runner/schema hashes, revision and dirty flag, sanitized checks, bounded stream hashes/counts and cleanup. It excludes raw server errors, paths, user agent, host/installation identifiers and stderr. Before starting any child, it atomically replaces an earlier result with a failed/starting report; an interrupted attempt cannot retain the older pass. This does not promise crash-durable storage or concurrent runs sharing one output path. Offline fake-peer regressions run in ordinary repository checks without Codex, credentials or model/network access; they cannot establish upstream behavior. Real observations and their limits are recorded in [project status](project-status.md), with field and network evidence in [protocol research](../references/codex-protocol-research.md).

### Native lifecycle with a synthetic provider

For actual app-server state transitions without a real model/account, reuse the same pinned native binary and schema bundles:

```sh
python3 scripts/probe-codex-turns.py --codex "$CODEX_NATIVE" \
  --schema-dir build/codex-schema-experimental \
  --default-schema-dir build/codex-schema-stable
```

The model is a deterministic, loopback-only Responses API fixture. Codex runs actual threads, turns, a fixed temporary-file command and persistence; assistant text/token counts come from the fixture. No credentials, external model/network, personal projects, app-server listener or product adapter are involved. The outer sandbox adds only outbound access to that one temporary localhost port. The same six denial guards still run; all tool children inherit the outer restrictions even after a fixture approval.

The fixed sequence completes text, cancels a bound command approval with no file creation, accepts a fresh bound approval and observes the actual file/command exit, interrupts a turn waiting for provider data, then gracefully stops Codex. A new process reads four matching turn IDs/terminals with metadata-only `thread/read` plus full `thread/turns/list`, resumes the original thread with explicit read-only/on-request permissions, and completes a fifth turn. It does not test real model quality/authentication, running-shell cancellation, pending approval replay, crashes, uncertain submission, mobile transport or device behavior.

Provider HTTP bodies are capped at 256 KiB, each socket operation at two seconds, each RPC/event wait at ten seconds, each native transport at sixty seconds, native events at 300 and streams at the no-turn limits. Only six provider requests/connections are expected; retries, unknown requests/events, cross-target approvals and duplicate terminal events fail. The temporary fixture has a random endpoint, no authentication/cookie input, no raw request logging, no persistent approval grants and bounded shutdown that interrupts active socket reads. These are diagnostic resource ceilings, not product performance claims.

The private atomic `build/codex-turn-probe.json` uses the same failed/starting invalidation. It records synthetic thread/turn IDs, observed states and sanitized event types, runner/transport/binary/schema hashes, stream counts/hashes and both process cleanups. It omits raw paths, provider request bodies, host/account metadata and stderr. Ordinary CI runs only local fake-peer/provider regressions; the native opt-in command must be rerun after runner changes and its provenance checked separately.

## Host submission authorization and crash windows

```sh
swift test --filter MunieExecutionHostTests
./scripts/check-submissions.sh
```

The root SwiftPM harness tests a Mac-only execution module; the shipping Xcode apps still use only MunieCore. Actual system SQLite tests cover authorization, permanent device revocation, immutable request identity, thread/project ownership, single/concurrent dispatch claims, positive upstream state evidence, path/symlink/inode changes, unknown schema/host, storage capacity failures, transaction rollback, private files and lifetime locks across processes. Fixtures use temporary canonical directories; no personal project, account or Codex is accessed.

`check-submissions.sh` builds `MunieSubmissionProbe` in Release and drives six actual process/terminal windows. Five SIGKILL cases stop at explicit pipe barriers with the owner lock still held: uncommitted dispatch update, accepted commit, dispatching commit, synthetic upstream effect and upstream mapping. A completed request supplies the terminal case. Each restarts the same store and retries twice. Only an unclaimed accepted request executes; uncertain requests remain reconciling and never automatically repeat an effect. A separate positive synthetic upstream record can reconcile already-executed cases without another effect. Every store open checks SQLite `quick_check(1)`; side-effect counts use append records, not a file-presence/touch test.

The atomic private `build/submission-ledger-probe.json` records native executable/runner/host-source/revision hashes, dirty state, runtime SQLite version, structured checkpoint results, effect counts and cleanup for every attempt. Output is capped at 4 KiB per line/16 KiB per stream, frame waits at ten seconds, transport lifetime at fifteen seconds and shutdown uses the bounded process-group cleanup shared by protocol diagnostics. Reports exclude request text, raw paths and stderr; stream counts/hashes remain. Compilation removes an old report before starting; execution publishes failed/starting before child startup. Ordinary repository tests cover malformed/flooding fake peers, orphan cleanup and stale-result rejection.

The experiment is a real Swift/SQLite recovery test with **synthetic** upstream effects. It does not prove external exactly-once execution, physical power-loss durability, real Codex reconciliation, network authentication, final-path handoff safety, user-data migration or any Apple device interaction. Storage configuration and the mature alternative are recorded in [ledger research](../references/submission-ledger-research.md); do not broaden this evidence to product remote execution.
