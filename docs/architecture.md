# Architecture

## Foundation

```text
SwiftUI app (apps/ios)
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

## Extension boundaries

Do not create empty packages for future platforms. Extract a package when a second real caller demonstrates shared policy, models or transport needs. Keep device APIs in their app/adapter targets.

| Future concern | Intended owner / gate |
|---|---|
| Mac execution gateway | Separate authenticated service/adapter; agent credentials stay on Mac |
| Remote task protocol | Shared models only after first adapter, stable request IDs and real state transitions |
| Watch UI / connectivity | Native watch target; shared domain, platform-specific entry and transport |
| Glasses | Official SDK adapter isolated from domain and app presentation |
| Search/memory | Start with local retrieval; adopt a mature indexed store when measured requirements justify it |
| Secrets | Platform secure storage; never domain records, repository or diagnostics |

Use dependency injection at behavior boundaries, not a large generic plugin framework. A second harness is the test of a reusable execution abstraction. Evaluate existing packages first and record maintenance, privacy, license and migration costs in the [registry](../references/README.md).

## Localization and data boundaries

English and Simplified Chinese are supported UI languages. Stable code identifiers and persisted fields remain language-neutral. Translate user-facing errors at presentation; do not serialize localized messages as state. Layout must tolerate Dynamic Type and longer translations.

Private user content belongs in application storage. `references/` holds third-party sources, `docs/research/` historical research, and `build/` disposable results. None of these directories is a substitute for a user-data model or an execution ledger.

See [ADR 0001](decisions/0001-native-modular-foundation.md) and [SECURITY](../SECURITY.md).
