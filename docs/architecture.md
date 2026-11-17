# Architecture

This page describes the implemented structure. Product scope lives only in [requirements](requirements.md); the planned remote Codex/voice boundary and task protocol live in the [remote Agent decision](decisions/remote-agent-foundation.md). Local capture is an auxiliary foundation, not proof of remote execution.

## Foundation

```text
SwiftUI multi-destination app (apps/Munie) + native Watch view (apps/MunieWatch)
  presentation and localized interaction
           ↓ CaptureStore (async, Sendable)
MunieCore (packages/MunieCore)
  CaptureRecord · validation · FileCaptureStore actor
           ↓
app-private versioned JSON file
```

`MunieCore` owns the domain and storage contract; it does not import SwiftUI, AppIntents, networking clients or an AI SDK. The app owns composition, platform paths, user-visible state and errors. Tests inject the store boundary. Native Foundation is sufficient for the first storage requirement; no external runtime dependency is required.

Records have stable UUIDs, text and creation time. The store validates input and persists through atomic replacement. Corrupt or unsupported data must surface as an error, not be silently replaced. One store actor owns one file; actor isolation is not a cross-process or cross-device lock. Before extensions or multiple processes write the same data, introduce a reviewed coordination/storage design.

Only show a record as saved after persistence succeeds. A local save does not imply submission to a model. Storage errors must remain visible and retryable without pretending success.

## Native Xcode and Swift Package layout

`project.yml` generates one ordinary `Munie.xcodeproj`. `Munie` is a native multi-destination application target for iOS/iPadOS, macOS, tvOS and visionOS. `MunieWatch` is a separate standalone watchOS application target; it reuses the app composition, presentation model, localization and core with a watch-specific view. Each app runs one store actor for its own file. Mac currently uses a single `Window` scene so multiple editors cannot overwrite the shared in-memory draft; multiwindow support requires separate draft ownership first. There is no Watch embedding, WatchConnectivity or cross-device synchronization. Tests remain separate targets under `apps/MunieTests` and `apps/MunieUITests`.

`packages/` is a project grouping, while each local package follows SwiftPM’s `Package.swift`, `Sources/<Target>` and `Tests/<Target>Tests` convention. Keep domain logic in `MunieCore`; platform adaptation stays in `apps/`. Shared compilation does not require identical interaction: TV uses system text input and detail actions, Watch uses a compact stack, and Mac omits mobile-only navigation modifiers.

Storage uses Application Support except on tvOS, where only a purgeable cache is promised and the composer warns about removal. Mac enables sandbox and hardened runtime settings. The current tvOS/visionOS targets still require native distribution artwork, and all new platforms need interaction/hardware acceptance. See [原生工程决策](decisions/native-apple-foundation.md) and the [platform matrix](standards/platform-acceptance.md).

## Extension boundaries

`apps/MunieHost/Execution` now contains a Mac-only `HostSubmissionLedger` actor, typed text requests and a small system SQLite boundary. The root SwiftPM harness builds/tests it and the actual `MunieSubmissionProbe` fault-injection caller; shipping Xcode app targets do not link it. It is not an authenticated remote gateway. This host module stays outside `MunieCore` until another real consumer demonstrates reusable domain behavior.

The ledger pins locally administered project directories and device grants, binds immutable request identities, commits accepted/dispatching stages before returning a single local dispatch claim, and records trusted upstream IDs/terminals. Reopen moves uncertain dispatching/running rows to reconciling without resending. SQLite storage uses private files, an exclusive cooperating-process owner lock and short rollback-journal transactions; capture JSON is neither reused nor migrated. See the [trust decision](decisions/remote-agent-foundation.md) and [storage evidence/limits](../references/submission-ledger-research.md). `HostCodexSession` now connects this ledger to a fixed-version `CodexAppServer` through the Codex-specific `CodexExecutionAdapter` seam. It claims durably before `turn/start`, persists native IDs, binds approvals/events/terminal state and reconciles only known IDs without blind resend. `CodexStdioTransport` owns nonblocking pipes, explicit launch inputs, bounded framing/queues/deadlines and verified EOF/leader/group cleanup. `MunieCodexHostProbe` is the local caller; a fixture-only guardian covers owner death before the launch identity is emitted. Raw native payloads remain host-only. See [bounded native experiment](testing.md#ledger-integrated-native-codex-experiment) and [process choice](../references/host-process-research.md).

`apps/MunieHost/NetworkProbe` is a separate Mac-only Foundation/Security executable for temporary loopback authentication research; it reuses the existing strict `CodexJSON` parser from the host module but never instantiates/calls the ledger or Codex adapter, and is not linked by shipping app targets. Its Python runner owns temporary certificates, the fixture server and process evidence. [Native network testing](testing.md#opt-in-native-apple-network-experiment) separates actual TLS/HTTP from offline callback/trust regressions.

`apps/MunieHost/LedgerNetworkProbe` now binds the TLS fixture server's verified peer-certificate fingerprint to a locally enrolled `AuthenticatedDevice` and calls the real ledger for each accept/snapshot. The Python bridge and private stdio channel are trusted local experiment control; ledger-only mode accepts HTTP submit/snapshot, while seed/revoke/claim remain local. Resume opens the existing schema without reseeding, preserving revoked devices and uncertain dispatch state. The native client distinguishes a real `ledger-snapshot` from the older in-memory fixture's acceptance ordinal. This remains a loopback research path, not production IPC, pairing, a gateway service or an app integration. See [authenticated-ledger testing](testing.md#opt-in-authenticated-ledger-network-experiment).

The same ledger probe now has an explicit six-argument Codex research mode. `LedgerCodexRuntime` owns the sandboxed native process/guardian, temporary provider configuration and coordinator. `LedgerCodexBridge` maps the verified connection identity before submit, snapshot, bounded event reads, one-time approval, interrupt or known-ID reconciliation. Tokens remain bound to the complete host-only native approval, device, request and live process; a restart cannot reuse them. Its HTTP runner permits only those fixed business operations; seed/revoke/claim, arbitrary RPC, identity and host paths stay outside the HTTP surface. The native client projects only fixed task/approval-state fields and verified fixture-marker observations, never raw native payloads. See [combined experiment](testing.md#opt-in-authenticated-network-to-native-codex-experiment).

Production authentication, mobile transport/presentation, media and a persistent host service remain future consumers. The combined experiment uses a deterministic provider and temporary local enrollment. Its informed research operator already knows and verifies the fixed command; the opaque approval token is not a shipping mobile approval presentation. It does not implement the full product capability inventory.

Do not create empty packages for future platforms. Extract a package when a second real caller demonstrates shared policy, models or transport needs. Keep device APIs in their app/adapter targets.

| Future concern | Intended owner / gate |
|---|---|
| Mac Codex gateway / task protocol | Local submission ledger, bounded Codex adapter and isolated authenticated network/native integration exist; production networking, enrollment and host supervision remain future work. Ownership, state and trust contract only in the [remote Agent decision](decisions/remote-agent-foundation.md) |
| Watch connectivity | Standalone native UI exists; transport, background work and pairing remain separate acceptance |
| Glasses | Official SDK adapter isolated from domain and app presentation |
| Search/memory | Start with local retrieval; adopt a mature indexed store when measured requirements justify it |
| Secrets | Platform secure storage; never domain records, repository or diagnostics |

Use dependency injection at behavior boundaries, not a large generic plugin framework. A second harness is the test of a reusable execution abstraction. Evaluate existing packages first and record maintenance, privacy, license and migration costs in the [registry](../references/README.md).

## Localization and data boundaries

English and Simplified Chinese are supported UI languages. Stable code identifiers and persisted fields remain language-neutral. Translate user-facing errors at presentation; do not serialize localized messages as state. Layout must tolerate Dynamic Type and longer translations.

Private user content belongs in application storage. `references/` holds third-party sources, `docs/research/` historical research, and `build/` disposable results. None of these directories is a substitute for a user-data model or an execution ledger.

See [原生工程决策](decisions/native-apple-foundation.md) and [SECURITY](../SECURITY.md).
