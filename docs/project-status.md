# Project status / 项目状态

Updated: 2026-11-17. Stage: engineering foundation / 工程基础。

Product scope is authoritative in [requirements](requirements.md): an Apple-native personal Agent frontend, open to multiple harnesses with complete native Codex support as the first target. Voice/device entry, media and proactive reports are planned; current local capture is auxiliary. [Foundation readiness](foundation-readiness.md) fixes the implementation order.

## Capability boundary

| Area | Implemented | Remaining acceptance |
|---|---|---|
| iPhone / iPad | Shared native SwiftUI app with local text capture, list/search, detail and confirmed deletion | Both-language UI, iPad layout, accessibility and real-device acceptance |
| Reusable core | Swift 6 model, validation and atomic versioned file storage | Personal data lifecycle and scale review before beta |
| Localization | 28 UI strings in English and Simplified Chinese; bilingual README | Both languages, Dynamic Type and VoiceOver on devices |
| Engineering | Native Apple targets and standard SwiftPM layout; Debug matrix, unsigned iOS Release build, Release core performance gate and documentation index checks | Real-device acceptance and signed distribution; exact-head hosted results tracked per feature PR |
| macOS / tvOS / visionOS | Native shared app compiles; Mac single window; TV system text input and purgeable cache warning | Runtime/UX acceptance; tvOS/visionOS native distribution artwork |
| watchOS | Compact native local capture/list/detail/delete UI; shared core, model and localization | Device interaction, accessibility and signed standalone delivery; no connectivity or sync |
| Agent guidance | Indexed semantic topic files, canonical requirements/state/decisions/standards; AI task contract and safe-maintenance rules | Semantic freshness still needs review; daily maintenance automation configured ACTIVE, not yet observed executing |
| Harness / remote execution | Open adapter contract and official research for seven harnesses; Codex 0.162.1 inventory: 266 methods, zero implemented. Isolated no-model stdio handshake/error experiment passed | Real thread/turn, events, approvals, cancellation, recovery, authenticated network and cellular → Mac acceptance remain unexecuted; research is not a product adapter |
| Voice / media / hardware entry | Apple/Qwen source and license research; Siri/Shortcuts, Watch, AirPods, Pencil, HomePod and CarPlay feasibility boundaries documented | No recording, media, notifications, device sync, remote adapter or hardware interaction implemented; runtime acceptance remains required |

Local capture is not an AI response or an executed task. Drafts remain in memory until saved; unsaved drafts do not survive process termination. No telemetry is collected by this foundation.

## Validation ledger

Local environment: Xcode 27.2 (27B52), Swift 6.4.2, macOS arm64; iOS Simulator SDK 27.2. Deployment minimums: iOS/iPadOS 18, macOS 15, watchOS 11, tvOS 18, visionOS 2. Hosted CI explicitly selects Xcode 26.2 on Apple Silicon `macos-26`.

| Check | Observed result |
|---|---|
| Core unit/integration | 14 Swift Testing tests passed, including concurrent writes, corrupt/versioned input and failed-write preservation |
| App presentation model | 6 tests passed on macOS, including failed save/delete, failed load and edits during an in-flight save |
| Reference sync safety | 10 Python tests passed; three pinned source checkouts synced and verified idempotently |
| Repository fixtures | 71 Python tests passed: simulator/package/Xcode contracts, Release failure propagation, document navigation/code examples, performance rejection, Codex schema/catalog drift/type regressions, and 23 subprocess protocol/cleanup/limit regressions. Fake peers do not establish upstream behavior |
| Core performance | Release synthetic 100/1,000-record list/save/delete budgets passed, 3 warmups + 20 samples each; reopened-store correctness. Raw samples/provenance in `build/core-performance*.json`; host storage only, no device/remote claim |
| Codex scope | Actual default/experimental CLI schema comparison passed: 200/266 methods across four message directions, all `unimplemented`. CI checks saved-catalog structure offline; live schema drift requires the explicit local comparison |
| Codex no-model stdio | Native 0.162.1 binary + saved schemas; six sandbox guards and six protocol checks passed. Pre-init / duplicate-init / missing-parameter / unknown-method / nonexistent-thread errors were `-32600`; initialize confirmed the isolated data path. Server exited 0 and process group disappeared. Report: ignored `build/codex-protocol-probe.json`; command and limits in [testing](testing.md#opt-in-local-codex-protocol-experiment) |
| Core smoke | `PASS capture → persist → reopen → delete → reopen` |
| Static / repository | Strict swift-format, actionlint, workflow parsing, local links, license hashes and localization checks passed |
| Apple platform builds | `./scripts/check.sh` exited 0: five SDK Debug builds (iOS `build-for-testing`) plus unsigned generic iOS device Release build; separate platform logs. Repository checks rerun after final review fixes |
| iOS simulator execution | Hosted app tests (6) and UI smoke (1) passed: save → relaunch → retrieve/detail → delete → relaunch. Latest local `./scripts/test-ios.sh` exited 1: no available iPhone simulator compatible with SDK 27.2; next action is hosted CI or install a matching runtime |
| Real device / cellular / Watch / Ray-Ban Meta | Not executed |
| GitHub | Public [repository](https://github.com/EitanWong/Munie); `main` default; both main/dev protected. [PR #2](https://github.com/EitanWong/Munie/pull/2) merged after [complete CI success](https://github.com/EitanWong/Munie/actions/runs/43935261007) on `68602b2`; foundation [PR #1](https://github.com/EitanWong/Munie/pull/1) and maintenance [PR #3](https://github.com/EitanWong/Munie/pull/3) are merged. Exact-head all-platform results belong in the feature PR and [CI history](https://github.com/EitanWong/Munie/actions/workflows/ci.yml) |
| Signed delivery | Not executed; Apple identity, profile/certificate/API secrets and protected TestFlight environment required |

Core source line coverage: `FileCaptureStore.swift` 85/86 (98.8%), `CaptureRecord.swift` 5/5. Host presentation model: 71/77 (92.2%). These are separate test runs, not whole-app or UI coverage. Raw logs/results belong in ignored `build/` and hosted artifacts.

The new targets share domain code, not device data. Watch stores records independently. tvOS uses a purgeable cache, with an English/Chinese warning; durable TV storage and synchronization require a separate design. Mac uses one window to prevent shared-draft collisions. No new platform hardware, HIG, App Store or signed-delivery acceptance is implied by compilation.

Independent app/config review identified the Mac shared-draft multiwindow issue and missing Watch input-limit feedback; both were corrected before the final full local check. Source changes and standard-layout regression guards are covered by that check. See [原生工程决策](decisions/native-apple-foundation.md), [Agent entry](agent/README.md) and [platform acceptance](standards/platform-acceptance.md).

## Next milestone

F0 [PR #6](https://github.com/EitanWong/Munie/pull/6) merged into dev at `f48e7612213dc271d06179dc7c3e7d9b6c4c52b6`; its [feature](https://github.com/EitanWong/Munie/actions/runs/43957541916), [dev](https://github.com/EitanWong/Munie/actions/runs/43960191729) and [draft release](https://github.com/EitanWong/Munie/actions/runs/43960202081) pipelines passed. F1 has started with the no-model stdio experiment; it is not complete. Next validate real thread/turn/event/approval/cancel behavior in a synthetic project, implement and test project authorization and uncertain-submit recovery, then select/verify the first authenticated network path using [protocol research](../references/codex-protocol-research.md). No service or paid account has been selected/configured. F2 is the engineering cellular→Mac loop; first user-usable scope also requires F3 short voice, native inputs/feedback and device acceptance. R16 full Codex support needs field/response/event and native-capability evidence, not just a successful turn. See the single [foundation sequence](foundation-readiness.md).

Protocol research found two material constraints: initialization/startup messages can include the host data path, hostname and installation ID even with temporary Codex data; only required sanitized fields may reach mobile/log output. Ordinary Watch apps cannot assume unrestricted WebSocket/SSH; evaluate HTTPS short requests and bounded state reads separately from iPhone streaming. Network candidates and their evidence are maintained in the remote decision/research, not selected by a successful local handshake.

Execute the [platform acceptance matrix](standards/platform-acceptance.md) for the corresponding shipping scope, starting with iPhone/iPad bilingual/accessibility/lifecycle, followed by Watch/AirPods native entry and feedback. Physical-device/配件、cellular、media、notification delivery and signed distribution have not run. tvOS/visionOS artwork remains a separate release gate; other platform scaffolds do not delay the primary remote path.

Before invited beta: registered signing identity, monitored private feedback/security path, actual data export/deletion and appropriate hardware acceptance. E1–E8 remain planned; no interviews, retention or product-market-fit results exist. Current hypothesis testing is owned by [product learning](product.md), not a second requirements list.

## Foundation review and maintenance

Independent reviews covered performance/Release gates, protocol inventory and requirement consistency. Corrected code-example links being mistaken for navigation, boolean/integer equivalence in catalog comparison, overly strong duplicate-execution wording, and stale capture-first scope. No third-party runtime/source or model weights were adopted. Consolidated numbered decisions into topic files and repaired maintained links; historical source reports remain attributed archives.

The Codex app daily heartbeat “维护 Munie 工程与文档” is configured ACTIVE and attached to this chat. It inspects actual state, avoids duplicate PRs and preserves user/uncommitted/reference data; this configuration is not evidence that a future scheduled run has executed. Per-change cleanup remains part of the engineering contract.

## PR maintenance

AI owns PR review, CI diagnosis/fixes, feedback/conflict handling, protected integration and cleanup, as specified in [AGENTS](../AGENTS.md) and [CONTRIBUTING](../CONTRIBUTING.md). Routine merges are authorized; signed TestFlight delivery retains owner approval. A skipped external bot review does not count as review; independent app/storage review for PR #2 reported no new material findings.

The first hosted attempt stalled before test startup on an old runtime. The corrected pipeline selects the newest SDK-compatible iPhone runtime, boots it explicitly (240s limit), bounds individual tests (120s default / 180s maximum), and retains logs/results. The successful run above includes the full capture lifecycle; earlier cancelled runs are not acceptance evidence. Later exact-commit results are available in [CI history](https://github.com/EitanWong/Munie/actions/workflows/ci.yml).
