# Native desktop product runtime

Checked 2026-11-18. Product intent is [R04](../docs/requirements.md): one Mac app and one iPhone app, with no terminal setup. Actual execution evidence belongs in [status](../docs/project-status.md). This document records component and packaging choices, not distribution approval.

## Reuse and provenance

The native `MunieDesktop` app wraps the already [adopted Remodex](remodex-adoption.md) bridge and relay. It does not replace their secure transport, project policy, recovery or native Codex implementation. A bounded JSONL control channel reports actual host/account state; local account requests never become mobile RPC methods. The existing C guardian supervises the worker process group through owner death. The relay listens on loopback for the bridge and a selected private LAN address for the phone; no public listener, hosted deployment or Funnel is provisioned.

| Component | Fixed input and terms | Product use |
|---|---|---|
| Node.js | Official 24.22.1 macOS arm64 archive, SHA-256 from the official HTTPS SHASUMS file; complete archive LICENSE is packaged. [Lock](desktop-runtime-lock.json), [release](https://nodejs.org/dist/v24.22.1/) | Bundled native executable; no Homebrew dylibs, npm or user-installed Node needed at runtime |
| Codex | Official npm `@openai/codex@0.162.1-darwin-arm64`, registry SHA-512 SRI and downloaded SHA-256 retained in lock; [source commit](https://github.com/openai/codex/tree/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d), original [Apache-2.0 license](licenses/codex-runtime.txt) | Native executable, code-mode host, ripgrep and zsh copied in their package-relative layout. Full transitive binary notices remain a distribution gate |
| Remodex dependencies | Existing reviewed npm locks; `npm ci --offline --ignore-scripts --bin-links=false` verifies archive SRI in developer/CI packaging | Only locked bridge/relay dependencies; no lifecycle bootstrap or global install |
| Multipeer Connectivity | Apple system framework, `.required` session encryption; SDK 27 marks the framework deprecated while the existing iOS 18/macOS 15 deployment range retains it | Mature local discovery and transport. A one-use CryptoKit commitment/reveal exchange binds the two displayed codes; both sides explicitly confirm before the actual Remodex bootstrap is released |

Apple declarations were checked in the installed SDK headers/interfaces for `MCSession`, `MCNearbyServiceAdvertiser`, `MCNearbyServiceBrowser`, `Process`, `FileHandle`, `NSOpenPanel` and application termination. [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity), [local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [Process](https://developer.apple.com/documentation/foundation/process) and [hardened runtime JIT entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit) are official references. The Mac helper's Node executable receives JIT entitlement when signed; the main app does not gain arbitrary unsigned-code/library-validation exceptions. Adoption of deprecated MPC is scoped to the two existing platforms, not a claim of future platform support.

## Existing Codex settings

The bundled CLI uses its [native configuration and credential storage](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/login/src/auth/storage.rs). File credentials and the Keychain account slot are tied to the Codex home. Munie does not parse, duplicate, or change the user's credential storage. The host forwards an existing absolute `CODEX_HOME` when available in the app's launch context and otherwise leaves the default to Codex. It does not load shell startup files or propagate arbitrary terminal-only environment variables. A native successful configuration load does not establish that the selected endpoint accepts requests.

## Packaging and limits

`prepare-desktop-runtime.py` and `package-desktop-runtime.py` are developer build tools. They verify fixed archives, extract named regular members, compile the existing guardian, install locked dependency archives with lifecycle scripts disabled, and assemble a fresh resource directory. `embed-desktop-runtime.py` checks every resource hash before copying it into the app and signs nested executables before outer signing. Runtime state, credentials and projects are never input directories. Product launch uses absolute bundled executables through `Process`; there is no fallback to `/opt/homebrew`, a shell, or global package installation.

`MUNIE_DESKTOP_COMPILE_ONLY=YES` is an explicit developer/CI compilation mode. It embeds no runtime and the app cannot claim readiness. It is rejected for archives. Local resource builds currently target Apple silicon; Intel archive provenance is not yet registered. Native Codex real-time voice runtime/dylibs are not packaged by this slice; iPhone opt-in short speech retains the existing bridge transcription path. No real audio acceptance is inferred.

Runtime notices/provenance, nested hardened signing/notarization and the existing Remodex distribution gates must all be resolved before distribution. Local bundling does not grant TestFlight approval. Nearby pairing does not establish an away-from-home network: ordinary users are not asked to configure VPN, ports or relay endpoints, and the new app explicitly marks away mode unavailable until a product-managed path is implemented.
