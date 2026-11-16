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

Do not create empty packages for future platforms. Extract a package when a second real caller demonstrates shared policy, models or transport needs. Keep device APIs in their app/adapter targets.

| Future concern | Intended owner / gate |
|---|---|
| Mac Codex gateway / task protocol | Primary future execution path; ownership, state and trust contract only in the [remote Agent decision](decisions/remote-agent-foundation.md) |
| Watch connectivity | Standalone native UI exists; transport, background work and pairing remain separate acceptance |
| Glasses | Official SDK adapter isolated from domain and app presentation |
| Search/memory | Start with local retrieval; adopt a mature indexed store when measured requirements justify it |
| Secrets | Platform secure storage; never domain records, repository or diagnostics |

Use dependency injection at behavior boundaries, not a large generic plugin framework. A second harness is the test of a reusable execution abstraction. Evaluate existing packages first and record maintenance, privacy, license and migration costs in the [registry](../references/README.md).

## Localization and data boundaries

English and Simplified Chinese are supported UI languages. Stable code identifiers and persisted fields remain language-neutral. Translate user-facing errors at presentation; do not serialize localized messages as state. Layout must tolerate Dynamic Type and longer translations.

Private user content belongs in application storage. `references/` holds third-party sources, `docs/research/` historical research, and `build/` disposable results. None of these directories is a substitute for a user-data model or an execution ledger.

See [原生工程决策](decisions/native-apple-foundation.md) and [SECURITY](../SECURITY.md).
