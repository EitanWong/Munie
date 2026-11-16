# Project status / 项目状态

Updated: 2026-11-17. Stage: engineering foundation / 工程基础。

## Capability boundary

| Area | Implemented | Remaining acceptance |
|---|---|---|
| iPhone / iPad | Shared native SwiftUI app with local text capture, list/search, detail and confirmed deletion | Both-language UI, iPad layout, accessibility and real-device acceptance |
| Reusable core | Swift 6 model, validation and atomic versioned file storage | Personal data lifecycle and scale review before beta |
| Localization | 28 UI strings in English and Simplified Chinese; bilingual README | Both languages, Dynamic Type and VoiceOver on devices |
| Engineering | Native multi-destination `Munie` target; separate standalone `MunieWatch`; standard local SwiftPM structure; all-platform CI builds | Real-device acceptance and signed distribution |
| macOS / tvOS / visionOS | Native shared app compiles; Mac single window; TV system text input and purgeable cache warning | Runtime/UX acceptance; tvOS/visionOS native distribution artwork |
| watchOS | Compact native local capture/list/detail/delete UI; shared core, model and localization | Device interaction, accessibility and signed standalone delivery; no connectivity or sync |
| Agent guidance | Root contract → task routing → Apple engineering/HIG → platform matrix → official sources | Recheck relevant official documentation for new APIs or release rules |
| Remote AI / Mac execution | Architecture and research only | Authenticated cellular → Mac task, replay and cancellation |
| Voice / Watch connectivity / glasses | Research only | Transport, permissions, hardware and distribution validation |

Local capture is not an AI response or an executed task. Drafts remain in memory until saved; unsaved drafts do not survive process termination. No telemetry is collected by this foundation.

## Validation ledger

Local environment: Xcode 27.2 (27B52), Swift 6.4.2, macOS arm64; iOS Simulator SDK 27.2. Deployment minimums: iOS/iPadOS 18, macOS 15, watchOS 11, tvOS 18, visionOS 2. Hosted CI explicitly selects Xcode 26.2 on Apple Silicon `macos-26`.

| Check | Observed result |
|---|---|
| Core unit/integration | 14 Swift Testing tests passed, including concurrent writes, corrupt/versioned input and failed-write preservation |
| App presentation model | 6 tests passed on macOS, including failed save/delete, failed load and edits during an in-flight save |
| Reference sync safety | 10 Python tests passed; three pinned source checkouts synced and verified idempotently |
| Repository fixtures | 12 Python tests passed: 4 simulator-selection fixtures and 8 SwiftPM/Xcode-graph contract regressions |
| Core smoke | `PASS capture → persist → reopen → delete → reopen` |
| Static / repository | Strict swift-format, actionlint, workflow parsing, local links, license hashes and localization checks passed |
| Apple platform builds | `./scripts/check.sh` passed locally after review fixes: iOS `build-for-testing`, native macOS build and tvOS/visionOS/watchOS generic simulator builds; separate platform logs |
| iOS simulator execution | Hosted app tests (6) and UI smoke (1) passed: save → relaunch → retrieve/detail → delete → relaunch. Latest local `./scripts/test-ios.sh` exited 1: no available iPhone simulator compatible with SDK 27.2; next action is hosted CI or install a matching runtime |
| Real device / cellular / Watch / Ray-Ban Meta | Not executed |
| GitHub | Public [repository](https://github.com/EitanWong/Munie); `main` default; both main/dev protected. [PR #2](https://github.com/EitanWong/Munie/pull/2) merged after [complete CI success](https://github.com/EitanWong/Munie/actions/runs/43935261007) on `68602b2`; foundation [PR #1](https://github.com/EitanWong/Munie/pull/1) and maintenance [PR #3](https://github.com/EitanWong/Munie/pull/3) are merged. Exact-head all-platform results belong in the feature PR and [CI history](https://github.com/EitanWong/Munie/actions/workflows/ci.yml) |
| Signed delivery | Not executed; Apple identity, profile/certificate/API secrets and protected TestFlight environment required |

Core source line coverage: `FileCaptureStore.swift` 85/86 (98.8%), `CaptureRecord.swift` 5/5. Host presentation model: 71/77 (92.2%). These are separate test runs, not whole-app or UI coverage. Raw logs/results belong in ignored `build/` and hosted artifacts.

The new targets share domain code, not device data. Watch stores records independently. tvOS uses a purgeable cache, with an English/Chinese warning; durable TV storage and synchronization require a separate design. Mac uses one window to prevent shared-draft collisions. No new platform hardware, HIG, App Store or signed-delivery acceptance is implied by compilation.

Independent app/config review identified the Mac shared-draft multiwindow issue and missing Watch input-limit feedback; both were corrected before the final full local check. Source changes and standard-layout regression guards are covered by that check. See [ADR 0002](decisions/0002-apple-platform-structure.md), [Agent entry](agent/README.md) and [platform acceptance](standards/platform-acceptance.md).

## Next milestone

Execute the [platform acceptance matrix](standards/platform-acceptance.md), starting with iPhone/iPad both-language, accessibility and lifecycle acceptance. Add native tvOS/visionOS distribution artwork before those platforms are eligible for a release. Use it personally to establish the original-method baseline and whether saved thoughts are later found and used. E1–E8 remain planned; no interviews, retention or product-market-fit results exist. See [product experiments](product.md).

Before invited beta: select registered bundle identity/signing, establish private feedback/security contact, validate export/deletion, and execute real-device acceptance. Implement one remote adapter only after its scenario and authorization requirements are fixed.

## PR maintenance

AI owns PR review, CI diagnosis/fixes, feedback/conflict handling, protected integration and cleanup, as specified in [AGENTS](../AGENTS.md) and [CONTRIBUTING](../CONTRIBUTING.md). Routine merges are authorized; signed TestFlight delivery retains owner approval. A skipped external bot review does not count as review; independent app/storage review for PR #2 reported no new material findings.

The first hosted attempt stalled before test startup on an old runtime. The corrected pipeline selects the newest SDK-compatible iPhone runtime, boots it explicitly (240s limit), bounds individual tests (120s default / 180s maximum), and retains logs/results. The successful run above includes the full capture lifecycle; earlier cancelled runs are not acceptance evidence. Later exact-commit results are available in [CI history](https://github.com/EitanWong/Munie/actions/workflows/ci.yml).
