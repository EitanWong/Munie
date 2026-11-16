# Reuse decisions

Status: 2026-11-17. This is an engineering record, not a redistribution license.

| Capability | Decision | Reason / next review trigger |
| --- | --- | --- |
| App and adaptive UI | SwiftUI and Apple system components | Native accessibility/localization and fewer dependencies; review third-party components only for an observed gap |
| Local capture persistence | Foundation + a small `MunieCore` package | Current local text scope does not need an external database; review SwiftData/GRDB when migrations, indexing, concurrency or query requirements justify them |
| Project generation | XcodeGen | Established declarative native-project generation; adopted as build tooling, not embedded in the app |
| Workflow validation | actionlint 1.7.12 | Established GitHub Actions static analysis; pinned official release, MIT license and platform-specific archive hashes; build-time only |
| State observation / tests | Apple Observation, Swift Testing / XCTest | Existing supported tools; no custom framework |
| Remote Mac/harness | Defer implementation; study Remodex, Happy and Chums | Preserve interchangeable backend boundary; do not fork a Codex-specific product for the entire frontend |
| Personal memory | Study Omi; do not transplant its mobile stack | Learn retention/deletion flows while retaining native Swift frontend ownership |
| Watch | Study Chums before implementing a separate module | Requires real-device connectivity/background/independent-network validation |
| Glasses | Study OpenVision and official Meta DAT | MIT application code does not grant SDK rights; pinned SDK has developer terms and experimental voice capability limits |
| Mimi Remote | No code adoption | GPLv3 applies; added permission addresses store conflicts only, not all copyleft requirements |
| RayBridge | No code adoption | No root license found at pinned commit; public visibility is not permission to copy |

Root-license snapshots in `licenses/` retain upstream copyright/permission text
verbatim. Their SHA-256, source URLs and exact commits are in `manifest.json`.
These research attributions do not assign any license to Munie's own code.

The latest registry may use a newer snapshot than the archived research reports.
Review the manifest diff before updating a pin; do not reinterpret old research as
validation of the newer source. A future dependency adoption must update this
record, the build manifest/lockfile, security review and user-facing notices.
