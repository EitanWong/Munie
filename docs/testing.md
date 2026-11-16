# Testing

## Automated layers

| Layer | Purpose |
|---|---|
| Core unit/integration | Validation, Unicode/limits, persistence/reload, deletion, corrupt/versioned data, concurrency and failed writes |
| Core smoke | Real temporary-file save → reopen → delete loop through the public API |
| App tests | Presentation behavior with injected storage, including failures |
| UI smoke | Capture → observe saved item → retrieve → delete on an iPhone simulator |
| Build/static | Swift formatting, repository/localization checks and generated iOS compilation |

Use tests to detect behavior regressions; avoid tests that merely repeat implementation or assert cosmetic trivia. Test data must be synthetic. Keep failed-write and corrupt-file evidence because data loss is a critical risk.

```sh
swift test --package-path packages/MunieCore
swift test # app presentation model on macOS
swift run --package-path packages/MunieCore MunieCoreSmoke
./scripts/check.sh
./scripts/test-ios.sh
```

`check.sh` runs static/repository/localization checks, core and host presentation tests with coverage, actionlint, the core smoke executable and a generic iOS build including app unit and UI test bundles. `test-ios.sh` runs app unit tests and UI smoke tests on the newest available iPhone runtime compatible with the selected Xcode SDK, with explicit per-test time limits (120s default, 180s maximum). Simulator boot has a 240-second limit; the CI simulator step has a 15-minute upper limit. Four fixture tests cover runtime/device selection. Use `IOS_TEST_DESTINATION` to select an explicit destination.

Do not report a build as a UI test, or a simulator run as hardware validation. The integrator records actual outcomes in [project status](project-status.md), with tool versions and environment limits. Hosted workflows need an observed run after a GitHub remote is connected.

## Device acceptance before beta

Run the same capture/save/relaunch/retrieve/delete loop on iPhone and iPad in English and Simplified Chinese. Review VoiceOver, Dynamic Type, keyboard handling, empty/error states and interrupted app lifecycle. Verify private file location, deletion semantics, device backup expectations and available disk failure behavior.

For future voice/remote work, extend only the relevant matrix: permissions revoked, locked/cold start, calls/audio interruptions, offline drafts, Wi-Fi↔cellular change, duplicate retry, cancellation, credentials revoked and host unavailable. Record literal inputs, state transitions and actual results. Same-LAN success does not establish outside-LAN operation.

No hardware, user-study, remote-task or distribution result is implied by the repository scaffold.
