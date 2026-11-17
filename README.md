# Munie

Your personal AI companion, close at hand.

[GitHub](https://github.com/EitanWong/Munie) · [简体中文](README.zh-Hans.md) · [Documentation](docs/README.md) · [Project status](docs/project-status.md)

Munie is a native Apple Agent frontend. The first iPhone–Mac slice pairs explicitly, selects authorized projects, accepts text or short voice input, runs actual Codex on the Mac, shows progress/results, answers one-time command approvals, cancels and continues tasks. Reconnect reads authoritative state before any retry. System Shortcuts open input and notifications route to their task.

Tailscale Serve on the Mac provides private HTTPS; Codex credentials stay on the Mac. This is a bounded subset for a pinned Codex version. Full native coverage, Watch remote tasks and media remain later goals. [Project status](docs/project-status.md) separates real-model, build, physical-device, cellular, voice and notification-delivery evidence. Other destinations retain local capture; Apple TV uses purgeable cache.

## Connect iPhone and Mac

1. Install and log in to Codex 0.162.1 on the Mac. Build/run the `MunieHost` Xcode scheme, start the service and explicitly authorize a project folder.
2. Install and sign in to the same Tailscale network on both devices. Configure private Serve HTTPS on the Mac to `http://127.0.0.1:9274`, with no public Funnel. An optional setup script is described in [testing](docs/testing.md#product-private-network-setup).
3. Enter the Mac's Tailscale HTTPS address and create a two-minute invitation. Scan or enter it in Munie on iPhone; compare both fingerprints, then confirm project access on the Mac.
4. Select a project and submit text. Voice starts only after an explicit tap; edit or discard its transcript. Use text when on-device speech is unavailable. Keep the Mac awake and online.

Approval applies only to its exact action; cancellation waits for the host's terminal confirmation. Revoke devices or delete terminal Munie history on the Mac; native Codex history is retained separately. Optional push requires an APNs-capable team and key; local alerts only reflect states already observed by the app.

## Start developing

Requirements: macOS and Xcode with Swift 6 and all Apple platform SDKs. Deployment minimums: iOS/iPadOS 18, macOS 15, watchOS 11, tvOS 18 and visionOS 2. Bootstrap downloads checksum-pinned XcodeGen 2.46.0 and actionlint 1.7.12 into ignored `.tools/`. Simulator tests also require an installed iPhone simulator runtime.

```sh
./scripts/bootstrap.sh
open Munie.xcodeproj
./scripts/check.sh
./scripts/test-ios.sh
```

Set your signing team and unique bundle identifier in ignored `config/Signing.xcconfig` before installing on a device. The generated Xcode project is ignored; edit `project.yml` instead. See [development](docs/development.md) and [testing](docs/testing.md) for individual checks and environment limits.

Start with the [Agent task index](docs/agent/README.md) and read only the relevant [Apple engineering and HIG guidance](docs/standards/README.md). These are maintained project rules with official sources, not a claim of Apple certification.

Documentation uses topic names and indexes, with one authoritative source per topic. [Maintenance](docs/maintenance.md) defines updates, obsolete-guidance removal and safe recurring cleanup; repository checks reject unindexed or numbered documentation.

## Repository

| Path | Responsibility |
|---|---|
| `apps/Munie/` | Native multi-destination SwiftUI app, shared presentation and resources |
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
