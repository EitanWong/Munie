# Testing

## Automated layers

| Layer | Purpose |
|---|---|
| Core unit/integration | Validation, Unicode/limits, persistence/reload, deletion, corrupt/versioned data, concurrency and failed writes |
| Core smoke | Real temporary-file save → reopen → delete loop through the public API |
| App tests | Presentation behavior with injected storage, including failures |
| UI smoke | Capture → observe saved item → retrieve → delete on an iPhone simulator |
| Build/static | Swift formatting, repository/localization checks and generated native builds for all five Apple SDK families |

Use tests to detect behavior regressions; avoid tests that merely repeat implementation or assert cosmetic trivia. Test data must be synthetic. Keep failed-write and corrupt-file evidence because data loss is a critical risk.

```sh
swift test --package-path packages/MunieCore
swift test # app presentation model on macOS
swift run --package-path packages/MunieCore MunieCoreSmoke
./scripts/check.sh
./scripts/test-ios.sh
```

`check.sh` runs static/repository/localization checks, core and host presentation/execution tests with coverage, actionlint, the host submission crash experiment, the core smoke executable, Release core performance budgets, generic Debug builds for iOS/iPadOS, macOS, tvOS, visionOS and watchOS (including the iOS test bundles), and an unsigned generic iOS device Release build. Each platform has a separate `build/*-build.log`. Run `./scripts/build-apple-platforms.sh` to repeat only generation and builds. `test-ios.sh` runs app unit tests and UI smoke tests on the newest available iPhone runtime compatible with the selected Xcode SDK, with explicit per-test time limits (120s default, 180s maximum). Simulator boot has a 240-second limit; the CI simulator step has a 15-minute upper limit. Four fixture tests cover runtime/device selection. Use `IOS_TEST_DESTINATION` to select an explicit destination.

Do not report a build as a UI test, or a simulator run as hardware validation. The integrator records actual outcomes in [project status](project-status.md), with tool versions and environment limits. Hosted workflows need an observed run after a GitHub remote is connected.

Repository checks inspect the generated Xcode graph (including the iPhone/iPad device family and separate watchOS target), the actual SwiftPM manifests and standard package source roots, localization and maintained documentation links. Fixture tests reject dropped platforms, missing source trees, invalid Watch embedding and hidden Release build failures. Documentation checks require topic filenames and index reachability, excluding code examples; semantic freshness still needs review. See [maintenance](maintenance.md).

## Device acceptance before beta

Run the same capture/save/relaunch/retrieve/delete loop on iPhone and iPad in English and Simplified Chinese. Review VoiceOver, Dynamic Type, keyboard handling, empty/error states and interrupted app lifecycle. Verify private file location, deletion semantics, device backup expectations and available disk failure behavior.

Apply the [Apple platform acceptance matrix](standards/platform-acceptance.md) to Mac, Watch, TV and Vision Pro as well. Native compilation is an engineering gate; focus/remote input, small-screen navigation, spatial input, accessibility, persistence limits, native artwork and signed distribution require their own evidence. tvOS uses purgeable cache, and no platform currently synchronizes records.

For future voice/remote work, extend only the relevant matrix: permissions revoked, locked/cold start, calls/audio interruptions, offline drafts, Wi-Fi↔cellular change, duplicate retry, cancellation, credentials revoked and host unavailable. Record literal inputs, state transitions and actual results. Same-LAN success does not establish outside-LAN operation.

No hardware, user-study, remote-task or distribution result is implied by the repository scaffold.

## Performance evidence

Run `./scripts/benchmark-core.sh` independently for the optimized synthetic store workload. Raw samples, provenance and budgets are defined only in the [performance standard](standards/performance.md). CI retains `build/core-performance*.json` and build logs; host measurements do not establish app search, real-device, voice or remote latency. Ordinary builds include `build/ios-release-build.log`; signing and distribution are still separate.

## Opt-in local Codex protocol experiment

After exporting and checking both schema bundles with the [Harness workflow](standards/harness-integration.md#codex-范围清单与漂移), select the actual native Mach-O executable, rather than an npm/shell launcher:

```sh
CODEX_NATIVE=/absolute/path/to/native/codex
python3 scripts/probe-codex.py --codex "$CODEX_NATIVE" \
  --schema-dir build/codex-schema-experimental \
  --default-schema-dir build/codex-schema-stable
```

This macOS-only research command requires the saved Codex 0.162.1 schema and an available `sandbox-exec`; it never installs Codex or falls back to an unrestricted run. It creates temporary data/config/workspace directories, passes a minimal child environment, denies real-home/Keychain reads, Keychain Mach-service access, writes outside its fixture and all network operations. Only the two system preferences IPC endpoints remain allowed so managed configuration is not silently replaced by defaults. Six guard checks run before Codex. Existing login/config/session files are not copied or modified.

The RPC sequence is fixed: pre-initialize nonexistent interrupt, initialize, initialized notification, duplicate initialize, invalid interrupt parameters, unknown method and nonexistent turn interrupt. No thread creation/resume, model turn, tool, approval, listener or real cancellation runs. Each response has a 10-second deadline, the transport has a 60-second deadline, lines are limited to 64 KiB and each output stream to 512 KiB. Initialization and the bounded shutdown both validate messages; unexpected server requests/notifications fail without a response. Cleanup closes stdin, escalates TERM/KILL and confirms process-group disappearance. This is a diagnostic transport, not a reusable production adapter.

The mode-600 `build/codex-protocol-probe.json` records the binary/runner/schema hashes, revision and dirty flag, sanitized checks, bounded stream hashes/counts and cleanup. It excludes raw server errors, paths, user agent, host/installation identifiers and stderr. Before starting any child, it atomically replaces an earlier result with a failed/starting report; an interrupted attempt cannot retain the older pass. This does not promise crash-durable storage or concurrent runs sharing one output path. Offline fake-peer regressions run in ordinary repository checks without Codex, credentials or model/network access; they cannot establish upstream behavior. Real observations and their limits are recorded in [project status](project-status.md), with field and network evidence in [protocol research](../references/codex-protocol-research.md).

### Native lifecycle with a synthetic provider

For actual app-server state transitions without a real model/account, reuse the same pinned native binary and schema bundles:

```sh
python3 scripts/probe-codex-turns.py --codex "$CODEX_NATIVE" \
  --schema-dir build/codex-schema-experimental \
  --default-schema-dir build/codex-schema-stable
```

The model is a deterministic, loopback-only Responses API fixture. Codex runs actual threads, turns, a fixed temporary-file command and persistence; assistant text/token counts come from the fixture. No credentials, external model/network, personal projects, app-server listener or product adapter are involved. The outer sandbox adds only outbound access to that one temporary localhost port. The same six denial guards still run; all tool children inherit the outer restrictions even after a fixture approval.

The fixed sequence completes text, cancels a bound command approval with no file creation, accepts a fresh bound approval and observes the actual file/command exit, interrupts a turn waiting for provider data, then gracefully stops Codex. A new process reads four matching turn IDs/terminals with metadata-only `thread/read` plus full `thread/turns/list`, resumes the original thread with explicit read-only/on-request permissions, and completes a fifth turn. It does not test real model quality/authentication, running-shell cancellation, pending approval replay, crashes, uncertain submission, mobile transport or device behavior.

Provider HTTP bodies are capped at 256 KiB, each socket operation at two seconds, each RPC/event wait at ten seconds, each native transport at sixty seconds, native events at 300 and streams at the no-turn limits. Only six provider requests/connections are expected; retries, unknown requests/events, cross-target approvals and duplicate terminal events fail. The temporary fixture has a random endpoint, no authentication/cookie input, no raw request logging, no persistent approval grants and bounded shutdown that interrupts active socket reads. These are diagnostic resource ceilings, not product performance claims.

The private atomic `build/codex-turn-probe.json` uses the same failed/starting invalidation. It records synthetic thread/turn IDs, observed states and sanitized event types, runner/transport/binary/schema hashes, stream counts/hashes and both process cleanups. It omits raw paths, provider request bodies, host/account metadata and stderr. Ordinary CI runs only local fake-peer/provider regressions; the native opt-in command must be rerun after runner changes and its provenance checked separately.

## Host submission authorization and crash windows

```sh
swift test --filter MunieExecutionHostTests
./scripts/check-submissions.sh
```

The root SwiftPM harness tests a Mac-only execution module; the shipping Xcode apps still use only MunieCore. Actual system SQLite tests cover authorization, permanent device revocation, immutable request identity, thread/project ownership, single/concurrent dispatch claims, positive upstream state evidence, path/symlink/inode changes, unknown schema/host, storage capacity failures, transaction rollback, private files and lifetime locks across processes. Fixtures use temporary canonical directories; no personal project, account or Codex is accessed.

`check-submissions.sh` builds `MunieSubmissionProbe` in Release and drives six actual process/terminal windows. Five SIGKILL cases stop at explicit pipe barriers with the owner lock still held: uncommitted dispatch update, accepted commit, dispatching commit, synthetic upstream effect and upstream mapping. A completed request supplies the terminal case. Each restarts the same store and retries twice. Only an unclaimed accepted request executes; uncertain requests remain reconciling and never automatically repeat an effect. A separate positive synthetic upstream record can reconcile already-executed cases without another effect. Every store open checks SQLite `quick_check(1)`; side-effect counts use append records, not a file-presence/touch test.

The atomic private `build/submission-ledger-probe.json` records native executable/runner/host-source/revision hashes, dirty state, runtime SQLite version, structured checkpoint results, effect counts and cleanup for every attempt. Output is capped at 4 KiB per line/16 KiB per stream, frame waits at ten seconds, transport lifetime at fifteen seconds and shutdown uses the bounded process-group cleanup shared by protocol diagnostics. Reports exclude request text, raw paths and stderr; stream counts/hashes remain. Compilation removes an old report before starting; execution publishes failed/starting before child startup. Ordinary repository tests cover malformed/flooding fake peers, orphan cleanup and stale-result rejection.

The experiment is a real Swift/SQLite recovery test with **synthetic** upstream effects. It does not prove external exactly-once execution, physical power-loss durability, real Codex reconciliation, network authentication, final-path handoff safety, user-data migration or any Apple device interaction. Storage configuration and the mature alternative are recorded in [ledger research](../references/submission-ledger-research.md); do not broaden this evidence to product remote execution.

## Ledger-integrated native Codex experiment

```sh
swift build -c release --product MunieCodexHostProbe
python3 scripts/probe-codex-host.py \
  --executable "$PWD/.build/release/MunieCodexHostProbe" --codex "$CODEX_NATIVE" \
  --schema-dir build/codex-schema-experimental \
  --default-schema-dir build/codex-schema-stable
```

This opt-in experiment connects the actual Swift coordinator/SQLite ledger, strict JSONL transport and fixed 0.162.1 client to native Codex. The same outer sandbox and six guards restrict the deterministic loopback provider; trusted fixture IDs replace authentication. No real model/account, external network, personal project or mobile endpoint is used. Ordinary `swift test` builds the probe; repository checks run offline guardian/driver regressions without installed Codex.

Eight scenarios verify text completion; bound approval cancel with no effect; one-time accept with exactly one append effect and command exit 0; interrupt of a running shell and child (both gone before transport close); native SIGKILL while approval is pending (known-ID reread becomes cancelled); native SIGKILL after a completed terminal but before the ledger commits it (known-ID reread becomes completed); host SIGKILL after native start but before mapping (reconciling, no mapping/resend); and host SIGKILL after spawn but before emitting its group identity. Driver fault barriers must occur once, in the exact expected phase and order. Provider validates the exact submitted user text and fixed final marker, not merely a plausible terminal.

The fixture-only Python guardian publishes a private, unique registry before launching native Codex in its owned process group. Parent death/EOF uses bounded input forwarding, close, TERM then group KILL, including the guardian if necessary. The driver independently checks the registered parent/group, process exit, EOF and group disappearance, and preserves cleanup failures. A process group is a cleanup scope, not a sandbox; escaping descendants remain an OS-isolation concern. This is not a production launch daemon or energy/performance benchmark.

Host waits are capped at 25 seconds, total host transport at 60 seconds, Swift session at 50 seconds, events at 256, JSONL frame at 1 MiB, stdin/stdout at 32 MiB each and stderr at 1 MiB. Guardian pending input is at most 64 KiB, EOF forwarding/close/TERM each at most .75 seconds, hard lifetime 120 seconds. These are diagnostic limits. Transport faults are tested independently with malformed/partial/flooding peers, backpressure, concurrent operations, cancellation and surviving descendants.

The atomic private `build/codex-host-probe.json` invalidates earlier success before startup. It records revision/dirty state, source/executable/runner/provider/guardian/binary/schema hashes, state transitions, effects, cleanup and stream counts/hashes; it excludes raw native payloads, host/account metadata, paths and stderr. A report alone cannot prove which source built a binary: preserve the same-run Release build command/status and binary hash. Rebuild and rerun after source/runner changes, including at the clean candidate commit. Known IDs require positive native history; missing IDs never authorize resubmission. Results do not establish full Codex support, physical power-loss durability, real authentication, sustained service behavior or device acceptance.

## Opt-in loopback authenticated-network experiment

This research fixture uses actual TLS 1.3 and HTTP, temporary CA/server/client certificates and a synthetic in-memory policy. It does not start Codex, load personal credentials, change system trust/network settings or expose a public listener. It is not the product gateway, pairing protocol or durable request ledger. Threats, alternatives, Apple constraints and real-model authorization prerequisites have one source in [network research](../references/authenticated-network-research.md).

Select a Python runtime that reports `ssl.HAS_TLSv1_3=True` and an explicit OpenSSL executable; unsupported Python fails with `failureCode=tls13-unavailable`, without silently downgrading. For the current local environment:

```sh
/opt/homebrew/bin/python3 scripts/probe-authenticated-network.py \
  --openssl /opt/homebrew/bin/openssl --output build/authenticated-network-probe.json
```

The report must say `passed`, with 23 cases, negotiated `TLSv1.3`, one acceptance before the capacity test, four fixture acceptances after it, `serverStopped`, `certificateFilesPrivate` and `temporaryCredentialsRemoved` all true, plus `pendingHeaderClosedOnCleanup` confirming active partial-header cleanup. Cases include both endpoint trust directions, hostname, unknown certificate mapping, forged identity/unauthorized project, retry/conflict/cross-device replay, duplicate JSON, ambiguous framing, 2,048-byte request bound, idle handshake/incomplete-body timeouts, worker recovery and revocation on the existing TLS connection and a new connection. The fixture stores at most four acceptance records; limits and TLS versions are research parameters, not measured product budgets. An identical retry returns the existing fixture record (200); first acceptance is 202, conflict 409, denied identity/project 403 and capacity rejection 429. No accepted record represents real Agent execution.

Socket inactivity and handshake timeout are three seconds; the body additionally has a three-second total read deadline. Python's HTTP parser has its own header limits, but this fixture has no total slow-header deadline or production denial-of-service protection. It is loopback-only and sequential. Reports invalidate an old success before starting, remain private (0600), omit raw bodies/keys and retain failure types. Cleanup actively closes accepted sockets before stopping the worker, so an incomplete HTTP header cannot hold the fixture open. Failure of server or credential cleanup is not a successful run. Offline regressions run in repository checks; this opt-in TLS experiment is separate and records the actual runtime/tool versions, source revision and script hash. No Apple client, real model, WAN/cellular, Watch, persistent pairing or CRL/rotation acceptance is implied.

## Opt-in native Apple network experiment

The Mac-only `MunieNativeNetworkProbe` executable uses actual Foundation `URLSession` and Security trust/identity APIs against the temporary loopback TLS fixture. Shipping Xcode targets do not link it; it reuses only the existing host module’s strict JSON parser and does not instantiate/call the ledger or Codex adapter, use personal identities or contact external services. Research constraints and official API availability have one source in [network research](../references/authenticated-network-research.md#mac-only-urlsession-原生身份研究卡).

Build the executable with `swift build -c release --product MunieNativeNetworkProbe`; select its absolute path from `swift build -c release --show-bin-path`. The runner requires a Python runtime with TLS 1.3 and an explicit OpenSSL executable:

```sh
/opt/homebrew/bin/python3 scripts/probe-native-network.py \
  --executable TARGET --openssl /opt/homebrew/bin/openssl \
  --output build/native-network-probe.json
```

`TARGET` is the just-built absolute executable path. Configuration, PKCS#12 passphrase and certificates are temporary private files, never command-line credential values. The native executable explicitly imports with `kSecImportToMemoryOnly=true` (macOS 15 minimum), validates the expected IP against the fixture CA only, scopes credential challenges to that HTTPS host/port and rejects redirects. Successful native metrics must show TLS 1.3 and no proxy; configured settings alone do not prove negotiation. It uses no shared credential/cookie/cache store; session invalidation and process EOF/group cleanup are required. This does not constitute a Keychain forensic audit or shipping Apple platform acceptance.

Offline native tests cover credential challenge rejection, actual `SecTrust` hostname/anchor evaluation with fixed synthetic certificates, bounded response callbacks and redirect rejection. They do not make real network requests. The opt-in experiment separately compares actual native results with server-side peer identity, rejection and acceptance counts. Record expected HTTP policy denial separately from TLS failure, and treat unknown results as failed evidence. Temporary credential and server cleanup must succeed even on failed attempts; retain unsuccessful reports separately. No native result is real Agent work.

The current macOS experiment has an explicit HTTP denial comparison: a legacy HTTP 403 control is observed as URL error `-1206` with no readable HTTP/body, while the candidate fixture returns domain denials as HTTP 200 with a fixed `error` envelope and keeps conflicts at 409. An HTTP 200 error envelope is a denial, never an accepted task; server acceptance counts must stay unchanged. This is a versioned research observation and candidate encoding, not the production protocol decision. The original Python-only 403 fixture remains unchanged. Untrusted client rejection additionally requires the server's certificate-verification failure, since a native connection-lost error alone is insufficient evidence.

In-flight cancellation uses an authenticated response with a two-byte advertised body: the server sends headers and one prefix byte, then withholds completion. The native response callback cancels before delivering any body data to its delegate. Acceptance requires the server's request barrier, `cancelledOnResponse=true`, HTTP 200, cancellation error `-999`, zero retained body bytes and no new fixture acceptance; it is separate from the slow-response timeout. This is HTTP transfer cancellation, not evidence of cancelling an Agent task.

## Opt-in local-key identity experiment

The separate `Apple identity SDK evidence` CI job runs `python3 scripts/probe-identity-sdk.py --output-dir build/identity-sdk` with the selected hosted Xcode. It preserves current public header/export evidence, project-minimum target triples and literal Swift 6 compile/link results for five device SDKs plus the iPhone simulator. Generated libraries are never executed. `probeCompleted` means the observation finished; `allAvailable` and each SDK's `available` separately require a public declaration, exported symbol and successful link. An unavailable API is recorded as unavailable, while tool execution/timeout/output-limit errors fail the probe. This diagnostic does not establish runtime, Keychain, simulator or hardware behavior. Use a fresh output directory with an existing parent for local runs.

This independent macOS fixture generates a volatile P-256 `SecKey`, signs a PKCS#10 CSR with pinned Apple X509 APIs and combines the synthetic returned certificate with the original key through public `SecIdentityCreate`. It exercises actual native URLSession/Security against two temporary loopback TLS listeners. The package is outside the root dependency graph and all shipping targets; default CI runs its offline Python regressions, license/pin checks and formatting, not its dependency build or actual network experiment.

```sh
./scripts/build-device-identity-probe.sh
PYTHON_TLS=/absolute/path/to/python3
"$PYTHON_TLS" -c 'import ssl; assert ssl.HAS_TLSv1_3, ssl.OPENSSL_VERSION'
"$PYTHON_TLS" scripts/probe-device-identity.py \
  --driver build/MunieDeviceIdentityProbe \
  --report build/device-identity-probe.json
```

Use a fresh report path for every attempt; existing evidence is never overwritten. The build script runs the fixture's Release lifecycle tests and uses ignored `references/checkouts/device-identity-build/` for SwiftPM scratch/cache/config/security with Keychain/netrc lookup disabled and the committed lock enforced. It requires the package's Swift tools version and a compatible Apple SDK. The observed local build uses Xcode 27.2; Xcode 26.2 compilation of this separate package has not been established. Python must be linked to TLS 1.3, and the runner requires an OpenSSL executable. On this machine the explicit Homebrew Python 3.15.2 uses OpenSSL 4.1.0; Xcode's default Python 3.9.6/LibreSSL 2.8.3 lacks TLS 1.3. That environment fails with `python-tls13-unavailable` before creating credentials or launching the driver; it never lowers TLS requirements.

Acceptance requires all nine named cases: valid, repeat-valid, same-CA unknown, wrong client CA, expired client, wrong EKU, no client certificate, wrong server anchor and wrong server hostname. CSR signature verification and a corrupted-signature rejection, exact public-key binding, identity leaf/possession checks and mismatched-key rejection must pass. The main server must observe exactly three HTTP requests: two accepted and one same-CA unknown domain denial. HTTP 200 with `denied` is not authorization success. The trusted-CA/wrong-SAN listener must receive no business request; both server-trust controls must reject before any client credential challenge. Native successful transport requires observed TLS 1.3 and no proxy.

All nine sessions must invalidate, driver streams must reach EOF with exit 0 and no stderr, its process group must disappear, both listeners/workers/active sockets must close, and all temporary CSR/certificate/issuer/server files must be removed. Per-command, frame, stream, connection and total-time bounds are recorded in the private report with runner/binary hashes and Python/TLS provenance. Failed attempts retain distinct reports and still run cleanup. Synthetic CA/server private keys are temporary files; only the device key stays in memory. Audited `keychainUsed: false` and `privateKeyExported: false` source constraints are not dynamic Keychain/memory-forensics evidence, reliable memory erasure, Secure Enclave or persistence. No product enrollment, Codex, real account, WAN, mobile runtime or device acceptance runs here. API and fixed dependency/license sources live in [network research](../references/authenticated-network-research.md#设备本地密钥续期与每用户-host-服务的可行性依据).

## Opt-in authenticated ledger network experiment

This separate Mac-only experiment connects the verified TLS peer identity to the actual `HostSubmissionLedger`, using temporary projects, certificates and SQLite files. The Python TLS server obtains the client leaf DER from the authenticated socket and sends its fingerprint over a trusted local pipe; the Swift driver maps it to the enrolled device. HTTP bodies cannot select trusted device identity, host, filesystem paths or administrative operations. The threat boundary and remaining production choices are maintained in [network research](../references/authenticated-network-research.md#tls-连接身份到真实账本的桥接研究卡).

Build both products with `swift build -c release`; obtain their absolute paths from `swift build -c release --show-bin-path`:

```sh
/opt/homebrew/bin/python3 scripts/probe-ledger-network.py \
  --native-executable NATIVE_TARGET --ledger-executable LEDGER_TARGET \
  --openssl /opt/homebrew/bin/openssl --output build/ledger-network-probe.json
```

`NATIVE_TARGET` is `MunieNativeNetworkProbe`; `LEDGER_TARGET` is `MunieLedgerNetworkProbe`. The driver has strict, bounded configuration/JSONL frames and private canonical fixture directories. Bootstrap requires empty state; resume requires an existing schema-1 database, without reauthorizing devices or creating a missing ledger. A nonempty schema-0 file must be refused unchanged. Local `claim` only tests durable dispatch permission; it does not execute an Agent/tool.

Acceptance requires the runner's exact named case sequence, all cases passed, native TLS 1.3/no-proxy evidence, independently read SQLite request identity/phase/counts, and live per-request authorization. Cover unknown certificates, cross-project/cross-device denial, body/header identity spoofing, duplicate JSON, forbidden HTTP administration, retry/conflict, same-connection revocation, new-connection revocation and driver SIGKILL/reopen. The revoked device stays disabled; previously dispatching records become `reconciling` without another send permission, while the unclaimed record stays `accepted`. Read and retry must refer to the original IDs. Neither state means execution completed. Domain denial over HTTP200 remains the research encoding, not authorization success.

Require normal driver exit 0 or the deliberate SIGKILL exit -9 as appropriate, EOF/group disappearance, native session invalidation/exit0, stopped server/listener and removal of all temporary credentials/projects/ledger files. Reports invalidate prior success and record source/executable hashes and bounded structural evidence without plaintext/keys/certificates. Offline validation and failure/cleanup regressions run separately in the repository checks. The trusted fixture pipe is not a production IPC security boundary or a general backpressure implementation; slow-header defense and host service supervision remain open. No Codex/model, real account, WAN/cellular, iOS/Watch, voice or hardware acceptance is performed.

## Opt-in authenticated network to native Codex experiment

This separate Mac-only experiment connects actual URLSession/Security, authenticated loopback TLS peer identity, the live SQLite ledger and the fixed-version native Codex adapter. The deterministic provider, projects, identities and tool effects are synthetic; shipping apps do not link the research executables. The design and remaining production decisions have one source in [network research](../references/authenticated-network-research.md#认证网络到原生-codex-的合成闭环研究卡).

Export and check both schema bundles using the [Harness workflow](standards/harness-integration.md#codex-范围清单与漂移). Select the absolute native Mach-O binary for `codex-cli 0.162.1`, rather than an npm/shell wrapper; the runner checks it against the saved schemas and capability catalog. It requires macOS, a Python runtime with TLS 1.3, an explicit OpenSSL executable and `/usr/bin/sandbox-exec`. It never installs/logs in to Codex or falls back to unrestricted execution. For the current local environment:

```sh
CODEX_NATIVE=/absolute/path/to/native/codex
swift build -c release --product MunieNativeNetworkProbe
swift build -c release --product MunieLedgerNetworkProbe
MUNIE_PROBE_BIN="$(swift build -c release --show-bin-path)"
/opt/homebrew/bin/python3 scripts/probe-network-codex.py \
  --native-executable "$MUNIE_PROBE_BIN/MunieNativeNetworkProbe" \
  --ledger-executable "$MUNIE_PROBE_BIN/MunieLedgerNetworkProbe" \
  --codex "$CODEX_NATIVE" \
  --schema-dir "$PWD/build/codex-schema-experimental" \
  --default-schema-dir "$PWD/build/codex-schema-stable" \
  --catalog "$PWD/references/codex-capabilities.json" \
  --openssl /opt/homebrew/bin/openssl \
  --output "$PWD/build/network-codex-probe.json"
```

Acceptance requires all six scenarios in this exact order, with native TLS 1.3/no-proxy metrics, independent SQLite identity/phase checks and no unexpected provider retry or tool effect:

| Scenario | Required observation |
|---|---|
| `text` | Exact synthetic input reaches the provider; matching native terminal is completed and the final assistant marker matches. |
| `approval-cancel` | The token maps to the complete fixed native command approval; one-time cancel reaches cancelled with no marker effect. |
| `approval-accept` | One-time accept reaches completed, with command exit 0 and exactly one append effect. |
| `running-interrupt` | PID barriers prove the shell and child started. Interrupt acknowledgement remains running with cancellation requested; a later terminal is cancelled, both tool processes disappear before native transport close and `after-interrupt` is absent. |
| `pending-crash` | SIGKILL stops the Swift bridge/host while approval is pending; the guardian cleans up native Codex. Reopen the same database/native state: exact retry is reconciling, the old token is invalid and matching known-ID native history reconciles to cancelled without resend/effect. |
| `revoked-pending` | A trusted local-pipe operation revokes device A; snapshot, approval, events and interrupt are then denied over the same TLS connection without new acceptance/effect. Revocation itself is not proof of upstream cancellation. |

Shared controls reject an unknown device, unauthorized project, changed-content retry, cross-device read/replay, wrong token and duplicate approval. An exact retry returns the existing phase; a terminal retry must add no provider request or effect. Pending approval survives a native-client/TLS reconnection by the same device, but its token does not survive host restart. Raw HTTPS attempts to supply trusted `deviceID`/`peerFingerprint` are rejected; `/fixture/revoke`, `/fixture/claim` and `/fixture/rpc` return 404. Only `submit`, `snapshot`, `events`, `approval`, `interrupt` and `reconcile` are mapped, with strict fields and actual TLS-socket peer identity. HTTP 200 with an error envelope remains a domain denial.

The fixture operator knows and validates the fixed synthetic commands before approving them. The token response does not present actual command/cwd for informed user approval, so it is not a releasable approval experience. There is one active coordinator task and a synchronous HTTP driver, without product event replay/cursor/backpressure or a production IPC guarantee. No real model/account, personal credentials, WAN/cellular, mobile app, pairing/gateway, voice, Watch, hardware or power measurement is covered; neither the complete uncertain-submission/mapping-loss matrix nor network-to-model service behavior is established. HTTP disconnect, URLSession cancellation, interrupt acknowledgement and process cleanup must not be treated as an upstream terminal.

Each scenario uses a separate `CODEX_HOME`, minimal environment, on-request/read-only permissions, one allowed loopback provider port and the same six sandbox denial guards. A separate same-profile control probe denies content reads/writes to TLS keys/identities/passphrase, host/client configurations, the ledger/registry and another project; it verifies unchanged control-file hashes and successful workspace/Codex-data/scratch roundtrips. The private guardian registry is published before native launch and its parent/group identity is checked; it remains fixture cleanup, not a product daemon or security boundary. HTTP requests/responses are capped at 2,048 bytes, driver input at 4,096 bytes and output at 2,048 bytes. Bridge startup/calls have 12-second waits and each bridge peer a 90-second lifetime; native transport has 20-second read and 60-second session limits. An event pump is capped at 128 observations and the facade at 256 events per request. These are diagnostic bounds, not measured product budgets or one total deadline for all six scenarios.

The selected private atomic report first replaces earlier success with failed/starting. A pass requires every scenario/check plus cleanup: native Apple client sessions invalidated with exit 0/EOF/group disappearance, bridge exit 0 or deliberate SIGKILL -9, guardian group disappearance, TLS server/provider stopped and temporary credentials/projects/ledger removed. Normal bridge closure additionally requires native Codex exit 0 with stdout/stderr EOF and its process group gone; after the deliberate host crash, the driver independently requires the guardian-owned native group to disappear. Cleanup failure remains failure evidence. The report keeps binary/schema/runner/source hashes, native metrics, SQLite phase/mapping, provider/effect counts, stream digests and structural cleanup; approval tokens are replaced with presence flags. Preserve the same-run Release build command/status and binary hash, then rebuild/rerun after source or runner changes; a report alone cannot prove which source built a binary. Record observed results and limits in [project status](project-status.md); offline regressions do not replace this opt-in run.
