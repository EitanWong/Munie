# Remodex source adoption

Checked 2026-11-18 at [Emanuele-web04/remodex `c06dcb16a7059603a41e26a2cb4a81b6d4b5514d`](https://github.com/Emanuele-web04/remodex/tree/c06dcb16a7059603a41e26a2cb4a81b6d4b5514d). This is the source/license decision; product behavior and executed acceptance remain in [project status](../docs/project-status.md).

## Adopted scope

The owner selected Remodex source as the rapid iteration base for the native iPhone client and actual Mac Codex bridge. The accepted Munie product implementation remains present. Keeping the existing bespoke client as the sole implementation would require recreating Remodex's conversation, Markdown, diff, git and recovery UI. Happy and Chums remain references; this slice does not adopt another mobile framework or execution harness.

| Upstream | Munie copy | Scope |
| --- | --- | --- |
| `CodexMobile/CodexMobile/**/*.swift` | `apps/MunieRemodex/App/` | Native Models/Services/Views and support source |
| `CodexMobile/CodexMobileTests/`, `CodexMobile/CodexMobileUITests/` | `apps/MunieRemodex/Tests/`, `UITests/` | Retained regression source with renamed module |
| `CodexMobile/RemodexWidget/*.swift` | `apps/MunieRemodex/Widget/` | Retained source; not evidence of an embedded/accepted extension. Launch intent also copied into `App/Shared/` |
| Upstream color sets | `apps/MunieRemodex/Resources/Assets.xcassets/` | Color values only; app icon comes from Munie |
| `phodex-bridge/` | `apps/MunieRemodexBridge/` | Node host source/tests and fixed npm lock |
| `relay/` | `apps/MunieRemodexRelay/` | Self-host relay/push source/tests and fixed npm lock |

The [source manifest](licenses/remodex-source-manifest.json) records each copied source path, destination, pristine SHA-256, byte count and Git mode. The bridge README's upstream symlink is materialized as a regular file containing its original link text; no external target is traversed. Paths preserve upstream source organization for review. Modified Swift/JavaScript files carry a prominent `Munie modification` notice. Package JSON and documentation changes are described in each destination's NOTICE and the generated diff. Root Apache-2.0 [license](licenses/remodex.txt) is retained in all three copied targets. The pinned checkout has no root NOTICE file.

Remodex's README explicitly reserves its name, marks and branding for forks. Munie uses its own product identity and app icon. Attribution may name the source; it does not grant use of Remodex marks. RevenueCat and the commercial free-send gate are removed for the self-hosted Munie target.

## Excluded upstream layers

| Layer | Evidence / decision |
| --- | --- |
| `Terminal/Vendor/GhosttyKit.xcframework` | Contains real static libraries (device archive 22,938,544 bytes), but checkout lacks its independent license, exact build source pin and complete notices. Excluded; current Ghostty MIT text cannot establish the bundled build's provenance |
| Geist/GeistMono/JetBrainsMono TTF files | Original app fonts excluded; Apple system fonts used. Their independent OFL terms are not replaced by Apache-2.0 |
| SVG/image assets and app/widget branding | Excluded. Individual upstream assets include Font Awesome CC-BY icon material, Lucide, third-party marks and unidentified CentralIcons paths. No blanket Apache asset clearance |
| `Resources/Mermaid/mermaid.min.js` | Excluded. SHA-256 `3e2002bf333907fae7c1d6860bbc78f5da417bc70b64f3d2268581ba0ba8b96a`, 2,963,890 bytes; no exact Mermaid build/version identified. Bundle includes DOMPurify, js-yaml, lodash/Underscore and Cytoscape legal banners. Local text fallback is required until an identified build and notices are selected |
| RevenueCat `purchases-ios-spm` | Removed from linked dependencies and reviewed lock; source subscription behavior replaced for self-host use |

## Fixed runtime dependencies and notice evidence

The [dependency archive](licenses/remodex-dependencies/manifest.json) records the 16 exact Swift dependency revisions retained from upstream `Package.resolved`, excluding RevenueCat. `config/Remodex.Package.resolved` is authoritative build input. A successful resolve with newer transitive versions does not satisfy this reviewed pin set.

| Component | Observed license layers |
| --- | --- |
| BigInt, Citadel, RemodexTextKit, Runestone, ConcurrencyExtras, SwiftUIMath, Tree-sitter, TreeSitterLanguages | Root MIT texts retained; embedded layers below remain distinct |
| SwiftASN1, SwiftCrypto, SwiftLog, SwiftNIO, SwiftNIO-SSH | Apache-2.0 with available NOTICE texts retained |
| SwiftAtomics, SwiftCollections, SwiftSystem | Apache-2.0 with Swift exception, complete texts retained |
| Citadel bcrypt / Blowfish | OpenBSD ISC/BSD notices preserved from exact C/header comments |
| SwiftCrypto BoringSSL | Exact upstream vendor pin `0226f30467f540a3f62ef48d453f93927da199b6`; complete BoringSSL LICENSE retained, distinct from SwiftCrypto Apache license |
| SwiftNIO CNIOLLHTTP | Additional embedded MIT license retained |
| Tree-sitter Unicode tables | Complete `lib/src/unicode/LICENSE` retained |
| RemodexTextKit Prism | Pinned build script identifies Prism 1.29.0; all 55 CDN component bytes match its checksum manifest and appear verbatim in the bundle. Verification hashes and MIT license from exact npm release retained. `LICENSE-3rdparty.csv` retained separately |
| SwiftUIMath math font bundle | Exact OTF SHA-256 and SFNT copyright/license name records retained individually: Asana Math, Euler Math, Fira Math, Garamond Math, KpMath Light/Sans, Lete Sans Math, Libertinus Math, Noto Sans Math and XITS Math declare OFL; Latin Modern Math and TeX Gyre Termes Math declare GUST. Complete bundled OFL/GUST texts and referenced LPPL 1.3c retained. Preserve font metadata and reserved names; do not relabel fonts MIT |
| `ws@8.21.0` | MIT; exact npm integrity and complete package license retained |
| `qrcode-terminal@0.12.0` | Apache-2.0 plus vendored Kazuhiko Arase QRCode MIT; complete combined package license retained |

Optional `ws` native peers are absent from the reviewed npm locks. Codex CLI remains a separately installed execution tool; source adoption does not copy account credentials or grant redistribution of another tool. npm research reads tarballs without executing install scripts.

TreeSitterLanguages explicitly acknowledges copied grammar/query repositories but supplies only its own root MIT license and no matching source revision or separate attribution for those origins. Every unresolved origin is named separately in `distributionBlockers` in the dependency manifest, including nvim-treesitter query material. This record does not infer those licenses. Before redistribution, match retained parser/query files to original sources and retain applicable notices, or replace/exclude the unresolved components.

The [readable combined notices](licenses/remodex-third-party-notices.txt) preserve identified complete license/notice texts and individual font name records. The tracked archive provides source-review evidence. Before distributing an app binary or Node package, include readable applicable third-party notices in the shipped artifact, verify its contents, and clear the individual grammar/query items. Compilation, internal tests and the default checker do not clear this distribution gate. TestFlight remains separately approved under the project contract.

## Reproduce the checks

```sh
python3 scripts/check-remodex-adoption.py
python3 scripts/check-remodex-adoption.py \
  --source-checkout references/checkouts/remodex \
  --report-directory build/remodex-adoption
python3 scripts/check-remodex-adoption.py --require-distribution-ready
python3 -m unittest discover -s scripts/tests -p 'test_remodex_adoption.py'
```

The default check verifies source presence, modified-file notices, excluded asset/binary boundaries, license hashes and fixed Swift/npm locks offline. The checkout mode additionally verifies clean origin/HEAD, authenticates original file bytes and emits a unified modified-source patch and machine-readable report. The explicit distribution check fails while any recorded item remains unresolved. Review and update the authoritative manifest, notices and locks together when changing a pin or source scope; the checker never resets the source checkout or changes an adoption decision.

## 简体中文

本次采用固定提交的 Remodex 原生 Swift 客户端、Node Mac bridge 与自托管 relay，保留来源、Apache-2.0 原文及修改标记。原字体、SVG/图片品牌资源、来源未确认的 Ghostty 二进制和 Mermaid bundle 不随新 target 引入；Munie 使用自己的名称与图标。

Swift/npm 的确切版本、独立依赖许可、字体元数据及 notice 原文由上面的清单维护。TreeSitterLanguages 内复制的每个语法/查询来源仍单独列为发行阻塞项；内部构建通过不代表已经完成这些许可归档。发行前还需确认 app 与 Node 包实际包含可读的完整第三方 notice；TestFlight 仍需单独授权。

## Incremental Munie product behavior

The primary client resolves automatic models from the host catalog (`isDefault`) or omits the model until that catalog arrives; explicit user and per-thread selections remain authoritative. The pinned upstream `gpt-5.5` fallback was rejected by the actual ChatGPT account. Signed iPhone E2EE task and separate-process recovery now pass on this fork; exact evidence and remaining acceptance live in [project status](../docs/project-status.md).

Short voice retains upstream bridge/ChatGPT transcription, now bounded to 30 seconds and cancelled on background or explicit cancellation. This does not inherit the earlier on-device Speech acceptance. Generation-owned setup/teardown, monotonic duration and bounded sample collection fix stale-start cancellation and timer tracking-mode defects; the full simulator suite includes their regressions. Test-only Keychain, preferences and encrypted file stores share a separate namespace, including a UUID for opt-in actual transport runs. Production storage paths remain unchanged.

The new-task system entry reuses the retained `NewMunieTaskIntent` contract and the adopted Home Screen compose-first route: foreground authentication, editable draft, explicit submission. Siri/Action button interaction and physical audio remain separate device checks.

Cancellation now indexes exact command ownership from bounded native events and uses the native background-terminal list/terminate APIs. A no-account/no-turn probe found that the pinned Codex binary exports item-history schemas while returning `-32601` for their execution; schema presence is not runtime support. Terminal publication and same-thread mutation stay gated while cleanup is uncertain. The adopted iPhone subsequently passed actual approval/cancel/continuation, separate-process recovery and the independent 31-second late-marker check. Evidence and remaining network/audio limits are in project status.

Local completion, failure, structured-input and approval notifications contain generic content rather than a user-derived conversation title or question. Remote push remains disabled by the launcher; retained upstream APNs previews require the same privacy migration before enabling that path.
