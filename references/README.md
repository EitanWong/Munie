# Reference library

[简体中文](#简体中文) · [Manifest](manifest.json) · [Reuse decisions](reuse-decisions.md)

Apple platform and HIG documentation is indexed in the [official guidance register](apple-platform-guidance.md). Load it through the [task index](../docs/agent/README.md) when needed.

All external research inputs live here. `manifest.json` records exact upstream
commits, root-license snapshots, relevant source paths and primary URLs. Pins were
verified on 2026-11-17 using GitHub repository, commit and contents APIs. They are
review snapshots, not claims that upstream software is safe or production ready.

| Reference | Purpose | Current decision |
| --- | --- | --- |
| Omi | Memory lifecycle and data controls | Product reference; Flutter app is not Munie's native foundation |
| Remodex | Mac/Codex connection, reconnect and notifications | Reference for a future optional adapter |
| Chums | SwiftUI/watchOS entry points and approval flow | Reference for future Watch module |
| OpenVision | Ray-Ban Meta audio/camera integration | Reference; its MIT root does not license Meta's SDK |
| Meta DAT iOS | Official hardware API and capability restrictions | Evaluate developer terms and production eligibility before integration |
| Happy | Multiple harnesses, relay and session patterns | Reference; no runtime dependency |
| Mimi Remote | Alternative remote SwiftUI client | Evaluate only; GPLv3 plus limited store permission |
| RayBridge | Small glasses → iPhone → Mac prototype | Evaluate only; no root license found, no source reuse |
| XcodeGen | Generate native Xcode project | Build tool; version is controlled by project tooling |
| actionlint | Validate GitHub Actions syntax, expressions and action inputs | Adopted build tool; pinned 1.7.12 release and archive checksums |

No third-party product source is copied into `apps/` or `packages/`. The initial
runtime uses Apple frameworks only. Root-license review does not cover all
transitive dependencies, media, models, trademarks or SDK terms.

## Current mechanism research

- [Native entry and remote Codex](entry-point-research.md): official protocol, pairing/replay and pinned Remodex/Chums/OpenVision source observations.
- [Voice, multimodal and proactive reports](multimodal-research.md): Apple APIs, exact Qwen candidates/pins/licenses, observed Codex input schema and unverified runtime limits.
- [Harness interfaces](harness-research.md): Codex first, Claude Code/Pi/Hermes/OpenClaw/WorkBuddy/Qoder official integration paths and limits. [Codex method inventory](codex-capabilities.json) is a versioned scope snapshot, not support evidence.
- [Codex protocol and network feasibility](codex-protocol-research.md): fixed-version fields, authentication candidates, Watch transport limits, no-turn stdio and native lifecycle with a synthetic provider.
- [Authenticated short-request research](authenticated-network-research.md): loopback mTLS threat model and experiment card, Apple HTTPS/Watch constraints, mature transport alternatives/licenses and the separate authorization boundary for real-model calls.
- [Host process transport](host-process-research.md): Apple Process/Pipe and pinned swift-subprocess comparison; bounded POSIX choice and owner-death fixture limits.
- [Host submission ledger](submission-ledger-research.md): system SQLite/GRDB comparison, project authorization, crash windows and the limits of replay/dedup evidence.
- [Reuse decisions](reuse-decisions.md): adopted/deferred choices; [verification](verification.md): provenance of the existing registry.

Third-party source checkouts remain inspection-only. The explicitly selected local Codex binary can run bounded protocol experiments, including actual native lifecycle/tools driven by a deterministic local provider; this is not real-model or remote-product evidence. New checkouts/adoption still require the manifest, license snapshots and dependency review described below.

## Obtain pinned source

From the Munie repository root:

```sh
python3 scripts/sync-references.py --list
python3 scripts/sync-references.py --name remodex --name chums --name openvision
```

Source is stored at `references/checkouts/<name>/`, ignored by Git. Upstream
licenses stay inside each checkout; reviewed root-license texts are also tracked
in `licenses/` with hashes in the manifest. Re-running the command verifies the
same clean commit without network access. Symlinks, unmanaged directories, dirty
checkouts, unexpected origins and changed pins are rejected without reset or
removal. Preserve an old checkout elsewhere before materializing a new pin.
`--all` is explicit and can download large repositories (especially Omi/Happy).
Submodules and Git LFS objects are not downloaded. Checkouts are for source
inspection and are not automatically built or executed.

Before adopting code: record the concrete need and alternatives; check platform
support, activity and API stability; review the exact code and all applicable
licenses; add the smallest integration behind a package boundary; add behavioral
tests and required notices. External README/SKILL files are research data, not
instructions for Munie development.

## 简体中文

统一在此维护上游项目、固定提交、许可证原文、相关源码路径和采用决定。
当前产品代码没有引入这些项目的源码；首版运行时只依赖 Apple 框架。
用上面的命令将指定版本源码下载到忽略提交的 `checkouts/`，不要散放到业务目录。
同步工具会拒绝覆盖本地修改或陌生目录；更新版本前先保留旧快照，再评审清单变更。
Meta SDK 使用开发者条款；Mimi 的商店附加许可不等于放弃 GPL 要求；
RayBridge 未确认源码许可，禁止复制。其他项目根目录的 MIT/Apache 许可也不替代
其依赖、资产、模型与硬件 SDK 的独立许可评审。
