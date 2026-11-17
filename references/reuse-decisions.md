# Reuse decisions

Status: 2026-11-17. This is an engineering record, not a redistribution license.

| Capability | Decision | Reason / next review trigger |
| --- | --- | --- |
| App and adaptive UI | SwiftUI and Apple system components | Native accessibility/localization and fewer dependencies; review third-party components only for an observed gap |
| Local capture persistence | Foundation + a small `MunieCore` package | Current local text scope does not need an external database; review SwiftData/GRDB when migrations, indexing, concurrency or query requirements justify them |
| Mac submission research ledger | System SQLite3, DELETE/EXTRA/fullfsync, one actor/connection and lifetime owner lock | Durable dispatch phases need transactions beyond capture JSON; [official guarantees and fixed GRDB alternative](submission-ledger-research.md). No third-party runtime or new package; reconsider GRDB if the fixed-SQL wrapper grows into a general storage framework |
| Bounded Mac process transport | Explicit POSIX actor behind `CodexRPCTransport`; fixture-only guardian | [Process/Pipe and swift-subprocess comparison](host-process-research.md); no copied upstream code/runtime dependency. Re-evaluate structured process runtime and idle energy before a persistent service or second host OS |
| Local-key identity research | Separate opt-in [device-identity fixture](../scripts/fixtures/device-identity/) with pinned SwiftCertificates / SwiftCrypto / SwiftASN1 | Public `SecIdentityCreate` assembles the returned certificate and matching caller-owned `SecKey` in memory; five current SDKs typechecked, Mac runtime results live in [status](../docs/project-status.md). Fixed pins and full core notices are [archived](licenses/device-identity/README.md). Research executable only; no root/shipping dependency, persistent Keychain enrollment, Secure Enclave or mobile runtime claim; review actual build cost and device lifecycle before adoption |
| Project generation | XcodeGen | Established declarative native-project generation; adopted as build tooling, not embedded in the app |
| Workflow validation | actionlint 1.7.12 | Established GitHub Actions static analysis; pinned official release, MIT license and platform-specific archive hashes; build-time only |
| State observation / tests | Apple Observation, Swift Testing / XCTest | Existing supported tools; no custom framework |
| Remote Mac Codex | First planned execution backend; study Remodex, Happy and Chums, own native frontend | Separate local app-server adapter from authenticated network boundary; see [remote/entry research](entry-point-research.md) |
| Personal memory | Study Omi; do not transplant its mobile stack | Learn retention/deletion flows while retaining native Swift frontend ownership |
| Watch | Native SwiftUI local capture target reusing MunieCore; no third-party code adopted. Chums remains a reference for connectivity | Local interaction/hardware acceptance pending; connectivity/background/independent-network validation is not implemented |
| Glasses | Study OpenVision and official Meta DAT | MIT application code does not grant SDK rights; pinned SDK has developer terms and experimental voice capability limits |
| Mimi Remote | No code adoption | GPLv3 applies; added permission addresses store conflicts only, not all copyleft requirements |
| RayBridge | No code adoption | No root license found at pinned commit; public visibility is not permission to copy |
| Voice / multimodal | Native short-session entry first; evaluate Qwen frontend separately | See [candidate pins and license layers](multimodal-research.md); no dependency, model or cloud service adopted |
| Performance harness | Foundation/ContinuousClock and auditable Release report | Three existing store operations do not yet justify a benchmark plugin; evaluate richer metrics when needed |

Performance alternatives reviewed on 2026-11-17: [ordo-one/benchmark](https://github.com/ordo-one/benchmark/tree/ade454725c54965ef78b3d2ea94e0fd699833f11) (Apache-2.0, asynchronous/multiple metrics and regression thresholds) remains a candidate for allocations/ARC/system calls or a larger suite; [google/swift-benchmark](https://github.com/google/swift-benchmark/tree/8163295f6fe82356b0bcf8e1ab991645de17d096) (Apache-2.0) is archived. Neither is adopted, copied or executed; recheck license and maintenance before adoption.

Root-license snapshots in `licenses/` retain upstream copyright/permission text
verbatim. Their SHA-256, source URLs and exact commits are in `manifest.json`.
The device-identity fixture's separate archive has its own manifest linked above.
These research attributions do not assign any license to Munie's own code.

The latest registry may use a newer snapshot than the archived research reports.
Review the manifest diff before updating a pin; do not reinterpret old research as
validation of the newer source. A future dependency adoption must update this
record, the build manifest/lockfile, security review and user-facing notices.
