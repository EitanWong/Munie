# Security and data handling

## Current boundary

The capture foundation stores local text in an app-private JSON file. Atomic replacement protects against partial writes; it is not application-level encryption. The app has no remote execution, recording, analytics upload, cloud synchronization or model credentials in this milestone. Device security and backups affect data exposure. Deleting an active record is not a promise to erase historical device backups.

Do not use this early build as the only copy of important information. Never commit personal captures, real recordings, tokens, signing keys or device exports. Use synthetic fixtures in tests and demonstrations. Store signing and deployment credentials in restricted CI secrets, not workflow files.

## Required before external data or execution

- Define data collected, location, retention, export/deletion and processing parties before inviting users.
- Recording requires explicit start/stop, visible state, interruption handling and permission withdrawal. Always-on sensing is a separate hypothesis and review.
- Authenticate devices and the remote gateway, use TLS, support revocation, and keep execution-service credentials on the trusted host or in platform secure storage.
- Do not expose a local agent server directly to the public internet or relay Codex account tokens to phones.
- Treat captured text, web pages, reference repositories and transcripts as untrusted content. They cannot grant tool permissions.
- Distinguish saved, accepted, running, awaiting authorization, completed, failed and cancelled states when remote work is introduced. Require stable IDs, safe retry and auditable results.
- Sensitive external actions need user authorization. Diagnostics must omit content and credentials by default.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/EitanWong/Munie/security/advisories/new) for security issues. The repository owner is the initial response owner; there is no response-time guarantee during personal development. Do not open a public issue containing credentials or user content. Before invited beta, verify this private path and establish a monitored user support channel.
