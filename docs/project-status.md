# Project status / 项目状态

Updated: 2026-11-17. Stage: engineering foundation / 工程基础。

## Capability boundary

| Area | Implemented | Remaining acceptance |
|---|---|---|
| iPhone / iPad | SwiftUI local text capture, list/search, detail and confirmed deletion | Chinese UI, iPad layout, accessibility and real-device acceptance |
| Reusable core | Swift 6 model, validation and atomic versioned file storage | Personal data lifecycle and scale review before beta |
| Localization | 27 UI strings in English and Simplified Chinese; bilingual README | Both languages, Dynamic Type and VoiceOver on devices |
| Engineering | `main`, `dev`, module `feat_` worktrees; generated Xcode project; CI/CD workflows | Real-device acceptance and signed distribution |
| Remote AI / Mac | Architecture and research only | Authenticated cellular → Mac task, replay and cancellation |
| Voice / Watch / glasses | Research only | Native entry, permissions, hardware and distribution validation |

Local capture is not an AI response or an executed task. Drafts remain in memory until saved; unsaved drafts do not survive process termination. No telemetry is collected by this foundation.

## Validation ledger

Local environment: Xcode 27.2 (27B52), Swift 6.4.2, macOS arm64; iOS Simulator SDK 27.2. Deployment minimum: iOS 18. Hosted CI explicitly selects Xcode 26.2 on Apple Silicon `macos-26`.

| Check | Observed result |
|---|---|
| Core unit/integration | 14 Swift Testing tests passed, including concurrent writes, corrupt/versioned input and failed-write preservation |
| App presentation model | 6 tests passed on macOS, including failed save/delete, failed load and edits during an in-flight save |
| Reference sync safety | 10 Python tests passed; three pinned source checkouts synced and verified idempotently |
| Simulator selection | 4 fixture tests passed: supported SDK/runtime, device availability, device family and booted preference |
| Core smoke | `PASS capture → persist → reopen → delete → reopen` |
| Static / repository | Strict swift-format, actionlint, workflow parsing, local links, license hashes and localization checks passed |
| Generic iOS | `build-for-testing` succeeded for app, app unit and UI test bundles, both simulator architectures |
| iOS simulator execution | Hosted app tests (6) and UI smoke (1) passed: save → relaunch → retrieve/detail → delete → relaunch. Local execution still requires an installed iPhone runtime |
| Real device / cellular / Watch / Ray-Ban Meta | Not executed |
| GitHub | Public [repository](https://github.com/EitanWong/Munie); `main` default; both main/dev protected. [PR #2](https://github.com/EitanWong/Munie/pull/2) merged after [complete CI success](https://github.com/EitanWong/Munie/actions/runs/43935261007) on `68602b2`; [foundation release PR #1](https://github.com/EitanWong/Munie/pull/1) retains its own integration check |
| Signed delivery | Not executed; Apple identity, profile/certificate/API secrets and protected TestFlight environment required |

Core source line coverage: `FileCaptureStore.swift` 85/86 (98.8%), `CaptureRecord.swift` 5/5. Host presentation model: 71/77 (92.2%). These are separate test runs, not whole-app or UI coverage. Raw logs/results belong in ignored `build/` and hosted artifacts.

## Next milestone

Install the app on iPhone/iPad for both-language, accessibility and lifecycle acceptance. Use it personally to establish the original-method baseline and whether saved thoughts are later found and used. E1–E8 remain planned; no interviews, retention or product-market-fit results exist. See [product experiments](product.md).

Before invited beta: select registered bundle identity/signing, establish private feedback/security contact, validate export/deletion, and execute real-device acceptance. Implement one remote adapter only after its scenario and authorization requirements are fixed.

## PR maintenance

AI owns PR review, CI diagnosis/fixes, feedback/conflict handling, protected integration and cleanup, as specified in [AGENTS](../AGENTS.md) and [CONTRIBUTING](../CONTRIBUTING.md). Routine merges are authorized; signed TestFlight delivery retains owner approval. A skipped external bot review does not count as review; independent app/storage review for PR #2 reported no new material findings.

The first hosted attempt stalled before test startup on an old runtime. The corrected pipeline selects the newest SDK-compatible iPhone runtime, boots it explicitly (240s limit), bounds individual tests (120s default / 180s maximum), and retains logs/results. The successful run above includes the full capture lifecycle; earlier cancelled runs are not acceptance evidence. Later exact-commit results are available in [CI history](https://github.com/EitanWong/Munie/actions/workflows/ci.yml).
