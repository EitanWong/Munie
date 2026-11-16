# Project status / 项目状态

Updated: 2026-11-17. Stage: engineering foundation / 工程基础。

## Capability boundary

| Area | Implemented | Remaining acceptance |
|---|---|---|
| iPhone / iPad | SwiftUI local text capture, list/search, detail and confirmed deletion | Simulator UI, accessibility and real-device acceptance |
| Reusable core | Swift 6 model, validation and atomic versioned file storage | Personal data lifecycle and scale review before beta |
| Localization | 27 UI strings in English and Simplified Chinese; bilingual README | Both languages, Dynamic Type and VoiceOver on devices |
| Engineering | `main`, `dev`, four `feat_` worktrees; generated Xcode project; CI/CD workflows | First hosted run; real-device acceptance |
| Remote AI / Mac | Architecture and research only | Authenticated cellular → Mac task, replay and cancellation |
| Voice / Watch / glasses | Research only | Native entry, permissions, hardware and distribution validation |

Local capture is not an AI response or an executed task. Drafts remain in memory until saved; unsaved drafts do not survive process termination. No telemetry is collected by this foundation.

## Validation ledger

Local environment: Xcode 27.2 (27B52), Swift 6.4.2, macOS arm64; iOS Simulator SDK 27.2. Deployment minimum: iOS 18. Hosted CI explicitly selects Xcode 26.2 on `macos-15`.

| Check | Observed result |
|---|---|
| Core unit/integration | 14 Swift Testing tests passed, including concurrent writes, corrupt/versioned input and failed-write preservation |
| App presentation model | 6 tests passed on macOS, including failed save/delete, failed load and edits during an in-flight save |
| Reference sync safety | 10 Python tests passed; three pinned source checkouts synced and verified idempotently |
| Core smoke | `PASS capture → persist → reopen → delete → reopen` |
| Static / repository | Strict swift-format, actionlint, workflow parsing, local links, license hashes and localization checks passed |
| Generic iOS | `build-for-testing` succeeded for app, app unit and UI test bundles, both simulator architectures |
| iOS simulator execution | Attempted; exit 1 with `No available iPhone simulator`. Runtime installation required; UI tests have not run locally |
| Real device / cellular / Watch / Ray-Ban Meta | Not executed |
| GitHub | Public [EitanWong/Munie](https://github.com/EitanWong/Munie) created; main default/protected; [foundation PR #1](https://github.com/EitanWong/Munie/pull/1); hosted checks in progress |
| Signed delivery | Not executed; Apple identity, profile/certificate/API secrets and protected TestFlight environment required |

Core source line coverage: `FileCaptureStore.swift` 85/86 (98.8%), `CaptureRecord.swift` 5/5. Host presentation model: 71/77 (92.2%). These are separate test runs, not whole-app or UI coverage. Raw logs/results belong in ignored `build/` and hosted artifacts.

## Next milestone

Run and observe hosted iOS tests, then install the app on iPhone/iPad for both-language, accessibility and lifecycle acceptance. Use it personally to establish the original-method baseline and whether saved thoughts are later found and used. E1–E8 remain planned; no interviews, retention or product-market-fit results exist. See [product experiments](product.md).

Before invited beta: select registered bundle identity/signing, establish private feedback/security contact, validate export/deletion, and execute real-device acceptance. Implement one remote adapter only after its scenario and authorization requirements are fixed.
