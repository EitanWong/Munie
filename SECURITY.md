# Security and data handling

## Current boundary

The capture foundation stores local text in an app-private JSON file. Atomic replacement protects against partial writes; it is not application-level encryption. The iPhone product additionally stores its Mac bearer in device-only unlocked Keychain and durable pending input in app storage. The Mac stores private bounded conversations, device/grant digests and a single-owner SQLite execution ledger; its separate Codex home contains the local account and native history. Explicit short voice uses on-device recognition and saves no audio. No analytics upload or general cloud synchronization is implemented. Device security and backups affect data exposure. Deleting an active record is not a promise to erase historical device backups.

Do not use this early build as the only copy of important information. Never commit personal captures, real recordings, tokens, signing keys or device exports. Use synthetic fixtures in tests and demonstrations. Store signing and deployment credentials in restricted CI secrets, not workflow files.

## Remote execution boundary

Private HTTPS terminates in separately installed Tailscale Serve on the execution Mac, then reaches a loopback-only listener. A short-lived invitation and exact fingerprint confirmation establish device/project grants; every business request checks its bearer and live grant. Revocation does not assert that native work is cancelled. There is no public Funnel, arbitrary mobile RPC or account token transfer. [Trust and service decisions](docs/decisions/device-trust-and-host-service.md) define the complete boundary and deferred mTLS/owner sharing.

The native adapter uses read-only/on-request permissions and an outer profile protecting host state; a project grant selects task scope and working directory, not a promise that any approved shell is confined to that folder. Exact one-time command approvals show their command/cwd/reason. Cancellation acknowledgement and native terminal are separate. Uncertain mappings remain reconciling without replay. Resource limits and known failure windows are recorded in [architecture](docs/architecture.md) and actual acceptance in [project status](docs/project-status.md).

Terminal Munie history may be removed on the Mac while request identities stay reserved. Native Codex history and backups are separate retained data. Full export/backup/migration, public beta support and broad device acceptance remain gates before inviting users. Optional APNs sends generic alerts with task/event IDs; provider keys remain in private host configuration.

## Continuing requirements

- Define data collected, location, retention, export/deletion and processing parties before inviting users.
- Recording requires explicit start/stop, visible state, interruption handling and permission withdrawal. Always-on sensing is a separate hypothesis and review.
- Authenticate devices and the remote gateway, use TLS, support revocation, and keep execution-service credentials on the trusted host or in platform secure storage.
- Do not expose a local agent server directly to the public internet or relay Codex account tokens to phones.
- Treat captured text, web pages, reference repositories and transcripts as untrusted content. They cannot grant tool permissions.
- Distinguish saved, accepted, running, awaiting authorization, completed, failed and cancelled states for remote work. Require stable IDs, safe retry and auditable results.
- Sensitive external actions need user authorization. Diagnostics must omit content and credentials by default.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/EitanWong/Munie/security/advisories/new) for security issues. The repository owner is the initial response owner; there is no response-time guarantee during personal development. Do not open a public issue containing credentials or user content. Before invited beta, verify this private path and establish a monitored user support channel.
