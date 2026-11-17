# Munie

Your personal AI companion, close at hand.

[GitHub](https://github.com/EitanWong/Munie) · [简体中文](README.zh-Hans.md) · [Documentation](docs/README.md) · [Project status](docs/project-status.md)

Munie is a native Apple frontend for Codex running on your Mac. Its primary iPhone implementation is a source fork of [Remodex](https://github.com/Emanuele-web04/remodex), retaining its conversation, Markdown, diff, project/git, approval and reconnect code under the Munie name. The previous native client/host remains a rollback checkpoint. The [requirements](docs/requirements.md) still govern voice, system entry, privacy, localization and later Apple platforms.

The adopted app is in acceptance testing. Its main controls have English and Simplified Chinese text, recording is limited to 30 seconds, and notifications return to the corresponding chat. Advanced UI translation, physical audio/system entry and notification delivery still need acceptance; see [project status](docs/project-status.md). Source pins, excluded upstream branding/binaries and distribution notice blockers are recorded in [adoption](references/remodex-adoption.md).

## Connect iPhone and Mac

1. Install Node.js 22+ and a native Codex executable on the Mac. Run `./scripts/setup-remodex.sh` to install locked dependencies without lifecycle scripts.
2. Prepare private directories on the Mac with `mkdir -m 700 -p "$HOME/Library/Application Support/MunieRemodex/state" "$HOME/Library/Application Support/MunieRemodex/codex-home"`, then sign in locally with `CODEX_HOME="$HOME/Library/Application Support/MunieRemodex/codex-home" /absolute/path/to/codex login`. Start `./scripts/run-remodex-local.sh --codex /absolute/path/to/codex --project /absolute/authorized/project --state-dir "$HOME/Library/Application Support/MunieRemodex/state" --codex-home "$HOME/Library/Application Support/MunieRemodex/codex-home" --advertise-relay wss://YOUR_HOST:8443`. Reuse these paths to retain pairing identity and native history. Without explicit paths the launcher creates a fresh private state/account. Startup submits no task.
3. Enroll the Mac and iPhone in the same private Tailscale network. On the Mac, configure Serve HTTPS on port 8443 to the loopback relay at `127.0.0.1:9275`; the iPhone connects through Tailscale. The launcher does not enroll an account or change Serve. Keep the Mac reachable and awake.
4. Build the `MunieRemodex` Xcode scheme, scan the launcher's QR code, then open the granted project and send a task. The client authenticates the scanned Mac identity and encrypts relay messages end to end. Credentials stay on the Mac.

The launcher preserves the earlier checkpoint service on port 9274. No TestFlight delivery, completed bilingual UX, microphone or background-push acceptance is implied by this setup. The [development guide](docs/development.md) and [testing guide](docs/testing.md) distinguish the adopted and retained schemes.

## Start developing

Requirements: macOS and Xcode with Swift 6 and all Apple platform SDKs. The adopted iPhone target requires iOS 18.6; retained foundation minimums are iOS/iPadOS 18, macOS 15, watchOS 11, tvOS 18 and visionOS 2. Bootstrap downloads checksum-pinned XcodeGen 2.46.0 and actionlint 1.7.12 into ignored `.tools/`. Simulator tests also require an installed iPhone simulator runtime.

```sh
./scripts/bootstrap.sh
open Munie.xcodeproj
./scripts/check.sh
./scripts/test-remodex-ios.sh
```

Set your signing team and unique bundle identifier in ignored `config/Signing.xcconfig` before installing on a device. The generated Xcode project is ignored; edit `project.yml` instead. See [development](docs/development.md) and [testing](docs/testing.md) for individual checks and environment limits.

Start with the [Agent task index](docs/agent/README.md) and read only the relevant [Apple engineering and HIG guidance](docs/standards/README.md). These are maintained project rules with official sources, not a claim of Apple certification.

Documentation uses topic names and indexes, with one authoritative source per topic. [Maintenance](docs/maintenance.md) defines updates, obsolete-guidance removal and safe recurring cleanup; repository checks reject unindexed or numbered documentation.

## Repository

| Path | Responsibility |
|---|---|
| `apps/MunieRemodex/` | Primary adopted native iPhone app, unit/UI tests and notices |
| `apps/MunieRemodexBridge/`, `apps/MunieRemodexRelay/` | Adopted Mac bridge and private self-hosted relay |
| `apps/Munie/` | Retained native multi-destination checkpoint and resources |
| `apps/MunieWatch/` | Watch-specific interaction in a separate watchOS app target |
| `apps/MunieTests/`, `apps/MunieUITests/` | App unit and iOS UI test targets |
| `apps/MunieMacHost/`, `apps/MunieHost/` | Native Mac host UI, supervised execution, ledger and transport |
| `packages/MunieRemote/` | Shared protocol, bounded transport and client recovery |
| `packages/MunieCore/` | Reusable capture models, durable storage and core tests |
| `docs/` | Product decisions, architecture, workflow, research and project status |
| `references/` | Pinned third-party registry and ignored source checkouts |
| `scripts/` | Reproducible local and CI automation |
| `.github/` | CI/CD workflows and contribution templates |
| `Package.swift` | Host modules, service/guardian executables and Mac tests |
| `config/` | Signing configuration template; personal values stay ignored |
| `project.yml` | Source of truth for the Xcode project |

`packages/` is a repository grouping convention, not an Apple-mandated name. Each package follows the standard `Package.swift`, `Sources/<Target>/` and `Tests/<Target>Tests/` layout. One generated `.xcodeproj` is sufficient; a separate `.xcworkspace` is unnecessary for these local Swift packages.

`main` is the release branch. Work integrates through `dev`; features use `feat_<module>_<purpose>` branches in sibling worktrees. See [CONTRIBUTING](CONTRIBUTING.md).

Prefer native capabilities and mature, license-reviewed components. Extract reusable packages from demonstrated shared behavior, not speculative device integrations. Current runtime dependencies and source references are documented in [architecture](docs/architecture.md) and [the reference registry](references/README.md).

## Privacy and distribution

Remote work needs the Mac’s local Codex account; independent local capture needs no model account. Stored text is sensitive user data; see [SECURITY](SECURITY.md). No product open-source license or distribution rights have been selected. Third-party projects retain their own licenses.
