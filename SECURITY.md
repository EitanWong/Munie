# Security and data handling

## Current boundary

The primary product is the adopted Remodex client/bridge/relay with a native Munie Mac companion. The Mac owns its private Codex account/state and authorized project; account operations use local control IPC and never become phone credential payloads. The iPhone retains the adopted device-trust and session storage. Explicit short recording is limited to 30 seconds and uses bridge/ChatGPT transcription with correction, cancellation and text fallback; it is not on-device-only speech recognition. Source/provenance and capability limits are in [adoption](references/remodex-adoption.md) and [project status](docs/project-status.md).

The retained capture foundation stores local text in app-private JSON; atomic replacement is not application-level encryption. The earlier native MunieHost/MunieRemote checkpoint separately uses device-only unlocked Keychain bearer storage, private bounded conversations and a single-owner SQLite ledger. Those schema/storage/voice implementation details do not describe the adopted client automatically. Device security and backups affect data exposure; deleting current app data does not promise to erase historical backups.

Do not use this early build as the only copy of important information. Never commit personal captures, real recordings, tokens, signing keys or device exports. Use synthetic fixtures in tests and demonstrations. Store signing and deployment credentials in restricted CI secrets, not workflow files.

## Remote execution boundary

The new two-app path uses nearby discovery and an expiring encrypted exchange with explicit matching-code confirmation on both devices before releasing the existing Remodex bootstrap. Discovery names do not grant trust. The phone then uses the adopted authenticated end-to-end encrypted WebSocket transport; the local relay binds loopback and one selected private LAN address. Bridge request/project policy applies before native forwarding. No public listener/Funnel is provisioned. This LAN path is not a claim that product-managed away-from-home connectivity exists. [Trust and service decisions](docs/decisions/device-trust-and-host-service.md) distinguish it from the retained private Tailscale HTTPS acceptance path.

In the retained native checkpoint, private HTTPS terminates in separately installed Tailscale Serve, then reaches a loopback-only Swift listener. A short-lived invitation/fingerprint confirmation establishes per-device bearer/project grants. Its fixed-operation HTTP API and grant schema are separate from the adopted protocol. Revocation is not confirmation that native work has stopped in either implementation.

The retained native adapter uses read-only/on-request permissions and an outer profile protecting host state; a project grant selects scope and working directory, not a promise that arbitrary approved shell commands are confined to that folder. The adopted bridge enforces its own native request/project policy and binds cancellation to observed native thread/turn/command ownership. Exact approvals must show their action and context. A cancellation ACK or native cancelled result does not by itself prove yielded shell cleanup. Unknown/conflicting ownership blocks continuation and terminal publication until confirmed. The native Mac container similarly retains failed cleanup and verifies exact recorded owner/group absence after a helper crash. Resource limits and known windows are recorded in [architecture](docs/architecture.md), actual acceptance in [project status](docs/project-status.md).

The retained ledger reserves request identities after terminal history deletion; that is not a claim about adopted storage semantics. Native Codex history and backups are separately retained. Export/backup/migration, public beta support and device acceptance remain gates. The adopted launcher disables remote push; local notifications use generic bilingual content and task routing. APNs requires separate implementation/privacy and delivery acceptance before enabling it.

## Continuing requirements

- Define data collected, location, retention, export/deletion and processing parties before inviting users.
- Recording requires explicit start/stop, visible state, interruption handling and permission withdrawal. Always-on sensing is a separate hypothesis and review.
- Authenticate devices and the gateway, preserve encrypted transport, validate TLS where HTTPS is used, support revocation, and keep execution-service credentials on the trusted host or in platform secure storage.
- Do not expose a local agent server directly to the public internet or relay Codex account tokens to phones.
- Treat captured text, web pages, reference repositories and transcripts as untrusted content. They cannot grant tool permissions.
- Distinguish saved, accepted, running, awaiting authorization, completed, failed and cancelled states for remote work. Require stable IDs, safe retry and auditable results.
- Sensitive external actions need user authorization. Diagnostics must omit content and credentials by default.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/EitanWong/Munie/security/advisories/new) for security issues. The repository owner is the initial response owner; there is no response-time guarantee during personal development. Do not open a public issue containing credentials or user content. Before invited beta, verify this private path and establish a monitored user support channel.
