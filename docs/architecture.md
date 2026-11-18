# Architecture

This page distinguishes the primary adopted implementation from the retained native checkpoint. Product scope is authoritative in [requirements](requirements.md), task-state semantics in the [remote Agent decision](decisions/remote-agent-foundation.md#task-state-contract), and security choices in the [trust/service decision](decisions/device-trust-and-host-service.md). Executed acceptance and remaining device/network limits belong in [project status](project-status.md).

## Primary Remodex product path

The new `MunieDesktop` Mac companion owns bundled Node/Codex, the existing Remodex worker/relay, account sign-in and the granted project. It exchanges bounded local JSONL state with the helper, and retains failed cleanup for retry instead of declaring shutdown from a native ACK. Resources and notices are verified during developer packaging; users do not install command-line dependencies. [Runtime provenance and gates](../references/desktop-product-runtime.md) describe the bundle independently of signed distribution.

`MunieNearby` is shared only by iPhone and Mac. Its local discovery advertises a name/version without bootstrap secrets. A bounded, expiring, one-use encrypted exchange shows the same verification code on both devices; user confirmation on both sides precedes release of the actual existing Remodex pairing payload. The iPhone then uses the same `CodexService` secure transport and task screens. Discovery is not device authorization. Local-network permission denial, unavailable Mac, cancellation and expiry remain explicit states.

Nearby pairing also owns the ordinary post-onboarding new-Mac and forgotten-pairing routes. A route remains visible through intermediate socket/trust state until its own initialized handoff commits; cancellation finishes teardown before retry. QR/manual codes are advanced recovery options. Compatibility prompts direct users to matching Mac/iPhone app versions without rendering developer commands. On Mac, removing pairing requires explicit confirmation and the exact current local device ID. The helper clears all existing phone trust and restarts the service; the UI warns that this disconnects phones and may stop active work. Failed restart is reconciled from actual status rather than restoring an obsolete pairing snapshot.

This new path is currently a nearby network product slice. It does not configure public infrastructure, enroll a VPN, or turn LAN acceptance into cellular acceptance. The private Tailscale path below is retained developer/acceptance infrastructure, not a required setup step in the new ordinary-user onboarding.

```text
Munie iPhone ← nearby discovery / matching-code confirmation → Munie Mac
      ↓ existing Remodex v2 bootstrap                         ↓ local JSONL
CodexService → authenticated E2EE WebSocket over private LAN → supervised worker
                                                             relay + Mac bridge
                                                                  ↓
                                                    project policy → native Codex
```

The complete client, bridge and relay source are adopted at the fixed revision in [adoption](../references/remodex-adoption.md). `MunieRemodex` is the primary iPhone scheme; upstream conversation/rendering/git/recovery APIs are retained. Self-host use removes the commercial subscription gate and upstream hosted endpoints. Branding uses Munie; unverified Ghostty libraries, Mermaid bundle, fonts and marks are excluded with visible fallbacks. Existing tests are retained and run through the new scheme rather than inferred from compilation.

The retained developer foreground launcher selects one canonical authorized project, a specific native executable and private state/Codex-home paths. In that acceptance launcher, bridge and relay are separate processes; the relay binds loopback and private Tailscale Serve exposes HTTPS :8443 to :9275. The new desktop worker instead owns the bridge and relay together, binding loopback plus one private LAN address and persisting the relay port for trusted resolution after restart. Account credentials are neither pairing fields nor mobile messages. The imported protocol has different trust, history and execution semantics from the earlier native ledger; its tests and real acceptance must establish those properties independently. See [project status](project-status.md) for current gaps. The old native modules remain available for comparison and rollback, without being placed underneath the new bridge.

The bridge checks the native method and authorized project before forwarding requests. Its cancellation controller binds a native thread, turn and command item from observed native events: interrupting a turn does not by itself terminate a yielded shell. A bounded ownership index survives relay reconnects; the pinned runtime rejects item-history RPCs despite exporting their schemas. The controller queries background terminals, terminates only those belonging to that exact turn and confirms their disappearance. Unknown or conflicting ownership holds terminal publication and same-thread mutations until cleanup can be confirmed. It never accepts a phone-supplied process ID. Exact tested capabilities for this implementation are separate from the retained adapter in the [versioned coverage record](../references/codex-product-coverage.json).

The client uses the native/catalog default model until the user makes an explicit selection. Recording is opt-in and capped at 30 seconds, with background cancellation and editable transcription through the local bridge. New-task Shortcuts open the compose flow before submission. Local completion, failure and approval alerts route back to the task; suspended delivery still requires separately configured APNs. DEBUG app-hosted tests isolate Keychain, preferences and encrypted files from production storage. `CodexService` uses an isolated MainActor destructor because a network callback may release its final reference off the main executor.

## Retained native checkpoint path

The protocol, host-state and on-device voice sections below describe the earlier Swift checkpoint. Their bearer/ledger/storage guarantees do not automatically describe the primary Remodex path above.

```text
iPhone / iPad: RemoteView → RemoteCoordinator → RemoteModel
                               ↓ MunieRemote / URLSession HTTPS
private tailnet → Tailscale Serve on the execution Mac (TLS termination)
                               ↓ HTTP on 127.0.0.1:9274 only
HostHTTPServer → ProductHost (authentication, grants, history, one active task)
                       ↙                          ↘
        ProductPersistence                 HostSubmissionLedger / SQLite
     private versioned history               durable dispatch authority
                                                      ↓
                                              HostCodexSession
                                                      ↓
                                              CodexAppServer 0.162.1
                                                      ↓
                                     CodexStdioTransport → C guardian
                                                      ↓
                                      sandbox-exec → native Codex app-server
```

The native `MunieHost` Mac companion owns these actors directly. Its local UI registers project folders, confirms pairing fingerprints and project grants, revokes devices, and starts/stops the listener. Closing its window leaves the menu-bar service running; quitting closes the runtime. `SMAppService.mainApp` provides an explicit opt-in login-item registration action. Registration, an awake/reachable Mac, a listening service, a compatible native executable and a usable Codex account are distinct conditions; native initialization alone does not establish a successful model call.

The Mac companion is a separate macOS target in `apps/MunieMacHost/`, with hardened runtime settings and no App Sandbox entitlement because it launches the separately installed native Codex executable. Native tools retain Codex's read-only/on-request policy; the outer profile denies access to the host enrollment/history/ledger directory. A project grant chooses an authorized canonical working directory and task scope; it is not a claim that arbitrary approved shell commands are confined by a separate project-only filesystem sandbox. Codex account material remains on the Mac in a dedicated private Codex home, initialized from the owner's existing local login without importing personal MCP configuration.

The C `MunieCodexGuardian` is embedded beside the Mac app's executables. It starts within the transport-owned process group, observes owner death without a later PID-publication step, waits for the native leader and clears remaining members of that group. It supplements transport EOF/leader/group cleanup; login-item registration does not provide that guarantee. Detached descendants that deliberately leave the group, signed login/logout/update behavior and physical power loss need separate acceptance. `MunieHostService` is a development/acceptance executable using the same runtime; its inherited local administrative pipe is not shipping IPC or a remote administration API.

Tailscale is an independently installed, trusted service on the same execution Mac, not a linked Munie library. HTTPS terminates there before a local plaintext HTTP hop. Munie does not describe that hop as TLS through to its Swift actor, expose an unencrypted LAN listener, trust forwarded identity headers, or use public Funnel. Both devices need a configured private tailnet route; installing a CLI does not prove sign-in, Serve, iPhone connectivity or cellular acceptance. Sources, alternatives and licensing are recorded in [product implementation research](../references/product-remote-implementation.md).

## Shared protocol and client ownership

`packages/MunieRemote/` is the shared, native Foundation package used by the iOS client and Mac runtime. It owns versioned fixed-operation DTOs, the bounded HTTPS client, pending-submission persistence and the `MainActor` presentation model. It contains no Codex credentials, SwiftUI view, recording implementation or generic remote shell endpoint. HTTP redirects and non-server-trust credential challenges are rejected; the normal initializer accepts HTTPS only. A separately named Debug initializer permits explicit loopback HTTP in automated tests.

The iOS composition stores its endpoint/host identity/bearer credential in non-synchronizing `WhenUnlockedThisDeviceOnly` Keychain storage. This protects storage access and migration; it does not prove Secure Enclave use or immediate erasure of an already loaded credential from memory on lock. A pending request ID and its original text/project/conversation are persisted before submission. Refresh and relaunch query authoritative state; they do not automatically resubmit. An explicit retry preserves the exact immutable request identity. A conversation ID remains stable across continuation, each new turn receives a new request ID, and the host resolves the native thread from its own stored mapping.

The iOS task list receives lightweight conversation summaries. Selecting a task requests its transcript, preventing retained history from making every status response exceed the transport limit. Client selection/generation/revision checks prevent stale responses from replacing a newer connection or turn. Cancel and approval requests bind both conversation and current request ID, so an old screen cannot control a subsequent continuation.

The app polls at two-second intervals only while its scene is active and an observed task remains nonterminal. Returning to the foreground and manual refresh query state. It does not claim a constantly running mobile background connection, automatic Mac wakeup or knowledge that a silent Mac is specifically asleep rather than otherwise unreachable. A disconnected phone does not stop the host's native event consumer.

## Host state, execution and recovery

`apps/MunieHost/Product/` contains the `ProductHost` actor and private atomic history storage. It owns device credential digests, project grants, conversations, messages, immutable request digests, cancellation intent, temporary pairing and pending native approvals. One active slot is reserved before a suspension; a different new request receives busy without a pretend queue. Requests remain bound to their origin device under ledger schema 1. Granting a second phone the same project does not give it the first phone's existing tasks; owner-level shared task visibility/read-only roles remain deferred.

`apps/MunieHost/Execution/` is now consumed by the product as well as the retained probes. `HostSubmissionLedger` pins canonical project directories and device grants, durably commits accepted/dispatching before a single dispatch claim, and persists native thread/turn/terminal evidence. It uses system SQLite, private files and an exclusive cooperating-process owner lock. The product history is a separate versioned file with its own owner lock, atomic replacement and file/directory fsync. Updates publish after persistence; failure to save does not skip native cleanup. Neither file storage nor actor isolation is a cross-store transaction.

`HostCodexSession` coordinates the ledger with the fixed-version `CodexExecutionAdapter`. `ProductHost` owns its single event-consumer task independently of HTTP clients. Mobile receives curated native assistant text, semantic progress codes, the exact supported command-approval description and authoritative task phases. Raw initialization/native payloads, account tokens and arbitrary RPC are not forwarded. Assistant deltas are bounded in host memory; completed message text is persisted without a disk fsync for every token. Command approval retains the complete native object host-side and exposes full command/cwd/reason with a short-lived one-time handle. Approval expiry requests an interrupt; an acknowledgement or transport closure is never a cancelled terminal.

After reopen, nonterminal product tasks become reconciling and old approvals disappear. The intact ledger's unknown-request or still-accepted state positively identifies a task that never reached dispatch; the product records failed/not-started and releases capacity without submitting it. Dispatch uncertainty, especially a missing native mapping, remains reconciling and cannot be blindly replayed. Known thread/turn IDs may be read to recover a positive terminal and a bounded assistant-only native-history result. Missing native history does not fabricate completion or an answer. History deletion on the Mac removes a terminal transcript while retaining immutable request/ledger records, preventing an old retry from recreating the work.

Implemented resource limits include one active task, 1,000 retained conversations, 10,000 request identities, 100 projects/devices, a 16 MiB product-history file, 32 KiB input text, 64 KiB encoded request body, a 2 MiB response, and bounded selected transcripts. Oversized assistant text is explicitly marked truncated; unsupported or oversized approval presentation fails closed. The local listener accepts one request per connection, caps connections and header/body bytes, and applies an overall connection deadline. These limits bound behavior; they do not establish latency, idle-power or physical-device performance acceptance.

## Voice, system entry and notifications

The iOS short-voice sheet explicitly requests microphone/speech access, records at most 30 seconds with `AVAudioEngine`, and requires available on-device Speech recognition. It saves no audio and supports stop, discard, transcript correction and text fallback. An unavailable language/device follows the text path. Audio interruption, route change and leaving the active scene stop recording without silently restarting it. `AppIntents`/Shortcuts navigate to input or a task; the owner may assign the input shortcut to a supported Action button. These entry points do not approve commands or start an unattended recording.

Local system notices describe newly observed authoritative completion, failure or pending approval, with generic content and task routing. They depend on observation and notification permission. Optional `HostPushNotifications` can send APNs alerts from locally supplied credentials and a registered device token; its bounded delivery queue does not hold the native reader or active slot. Missing configuration, rejected APNs requests, Focus, disabled notifications and delayed delivery leave manual state queries available. APNs credentials/entitlements and real background delivery require separate setup and acceptance; implementing the sender does not establish that they ran.

## Existing foundation and other destinations

`MunieCore` continues to own local `CaptureRecord`, validation and atomic `FileCaptureStore` storage without app UI, AppIntents or a harness dependency. Local capture remains auxiliary and does not imply remote execution. The existing native `Munie` multi-destination target retains its Mac/TV/Vision capture views; the iOS destination now uses the remote task experience, while the old capture UI automation has its explicit Debug fixture entry. `MunieWatch` retains its independent compact local-capture foundation. Shared source alone does not synchronize Watch, TV or Vision data or enroll those devices.

The Xcode project is generated from `project.yml`. Local packages use normal SwiftPM `Sources/<Target>` and `Tests/<Target>Tests` layout; root package products expose Mac runtime modules and diagnostic executables. Keep device APIs in app targets and extract further packages only for real shared behavior. English/Simplified Chinese catalogs translate product labels, errors and semantic progress codes; user/native assistant content remains data. TV local storage remains purgeable cache storage, and TV/Vision distribution artwork remains a separate gate.

## Research and capability boundaries

The loopback `NetworkProbe`, `LedgerNetworkProbe`, `CodexProbe`, submission fault experiments and separate local-key/mTLS fixtures remain research/acceptance callers. Their synthetic identities/providers and temporary credential dependencies are not shipping pairing or real-model evidence. The [deferred mTLS design](decisions/device-trust-and-host-service.md#deferred-mtls-alternative) remains available for a later concrete need without blocking the present iPhone path.

The product adapter supports a specific native text-turn subset: initialized pinned Codex, new/resumed threads, text turns, curated events/results, the supported one-time command approval and interrupt/history recovery. It does not implement all methods in the [versioned capability inventory](../references/codex-capabilities.json), arbitrary desktop-session takeover, additional harnesses or every Codex approval/tool/media capability. Build, synthetic tests, real-model loopback, signed devices, cellular access and notification delivery must retain separate evidence in [project status](project-status.md) and the [platform matrix](standards/platform-acceptance.md).

Private content belongs in app/host storage, reference evidence in `references/`, maintained guidance in `docs/` and disposable reports in ignored `build/`. See [SECURITY](../SECURITY.md) and [native foundation](decisions/native-apple-foundation.md).
