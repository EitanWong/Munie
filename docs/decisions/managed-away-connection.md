# App-managed away connection / App 管理的离家连接

Status: isolated admission prototype. Not enabled for either app or any relay listener.

## Decision

Keep explicit nearby confirmation as the only enrollment path. Reuse the [adopted Remodex implementation](../../references/remodex-adoption.md), its existing device keys and the v2 encrypted task channel. Do not publish the local relay or its pairing-code, push, or account control routes. Application encryption does not make a relay connection eligible to take over a route.

For a pilot, the Mac app should opt in to one fixed Munie HTTPS/WSS origin and initiate an outbound connection; the operator enrolls the Mac's public key. The hosted service should accept only authenticated reconnects from the phone already approved on that Mac. Keep LAN and WAN as separate route hints for the same pinned identity, with one bridge and one active telephone route. Changing paths must not create a second Codex runtime or resend an unconfirmed task. Failure to reach an endpoint permits fallback for the same Mac; invalid identity or authoritative revocation does not. Commit a route only after the existing v2 handshake and initialization succeed.

## Prototype and deployment gates

The [admission module](../../apps/MunieRemodexRelay/managed-admission.js) uses Node's standard Ed25519 APIs and no new dependency. Its one-use, 15-second challenge binds the audience, role, exact public keys, nonce and registration generation. Registrations are bounded by a configured pilot allowlist and pending challenges by a fixed capacity. Expiry uses service time. A replacement or deactivation invalidates old proofs; generation checks let the eventual listener reject a stale callback. This in-memory module does not open a port, provision keys, close sockets, or carry task data.

Before enabling an endpoint, require ordinary TLS certificate validation, bounded requests and upgrades, admission and route replacement as one operation, per-role issuance limits before challenge allocation, and no public pairing or push routes. Bind disable, disconnect and revocation to the correct sockets. Deactivation clears one registration; it does not prevent the allowlisted Mac from registering again, so the Mac adapter must stop registration on disable and only register currently trusted phones. Verify outage/fallback and replay with generated keys and no external account. Only then choose the hosting operator, service domain, capacity budget and minimal operational metadata retention. No deployment, cost commitment or credential access is part of the prototype.

Physical acceptance is separate: match the nearby codes on the actual Mac and iPhone, complete an authorized task and approval/cancellation, then reconnect the same thread over cellular with no VPN, return to LAN, and verify behavior after relay outage and revocation. Keep the control disabled in release until these gates pass.
