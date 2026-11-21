# Munie

Your personal AI companion, close at hand.

[GitHub](https://github.com/EitanWong/Munie) · [简体中文](README.zh-Hans.md) · [Documentation](docs/README.md) · [Project status](docs/project-status.md)

Munie is a native Apple frontend for Codex running on your Mac. Its primary iPhone implementation is a source fork of [Remodex](https://github.com/Emanuele-web04/remodex), retaining its conversation, Markdown, diff, project/git, approval and reconnect code under the Munie name. The previous native client/host remains a rollback checkpoint. The [requirements](docs/requirements.md) still govern voice, system entry, privacy, localization and later Apple platforms.

The adopted app is in acceptance testing. Its main controls have English and Simplified Chinese text, recording is limited to 30 seconds, and notifications return to the corresponding chat. Advanced UI translation, physical audio/system entry and notification delivery still need acceptance; see [project status](docs/project-status.md). Source pins, excluded upstream branding/binaries and distribution notice blockers are recorded in [adoption](references/remodex-adoption.md).

## Connect iPhone and Mac

The product setup is two apps: Munie on your Mac and Munie on your iPhone. In the new local desktop build:

1. Open Munie on the Mac, sign in to Codex in the browser when prompted, and use the default workspace or choose a project folder.
2. Open Munie on the iPhone and choose the automatically discovered Mac.
3. Compare the code on both screens and confirm the pairing. Then start a task from the phone.

Dependencies, local service startup and connection details belong inside the Mac app. Ordinary setup has no terminal commands, npm installation or server-address fields. Nearby connections are the current product slice; away-from-home automatic connectivity remains unfinished. Local build/acceptance and distribution limits are recorded in [project status](docs/project-status.md). Installable public releases are not yet available; [development](docs/development.md) contains developer-only build and retained network diagnostics.

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
| `apps/MunieDesktop/`, `apps/MunieDesktopTests/` | Native Mac companion, bundled execution lifecycle and offline app tests |
| `apps/MunieRemodexBridge/`, `apps/MunieRemodexRelay/` | Adopted Mac bridge and private self-hosted relay |
| `apps/Munie/` | Retained native multi-destination checkpoint and resources |
| `apps/MunieWatch/` | Watch-specific interaction in a separate watchOS app target |
| `apps/MunieTests/`, `apps/MunieUITests/` | App unit and iOS UI test targets |
| `apps/MunieMacHost/`, `apps/MunieHost/` | Native Mac host UI, supervised execution, ledger and transport |
| `packages/MunieRemote/` | Shared protocol, bounded transport and client recovery |
| `packages/MunieNearby/` | Bounded, explicitly confirmed nearby discovery and pairing shared by iPhone and Mac |
| `packages/MunieCore/` | Reusable capture models, durable storage and core tests |
| `docs/` | Product decisions, architecture, workflow, research and project status |
| `references/` | Pinned third-party registry and ignored source checkouts |
| `scripts/` | Reproducible local and CI automation |
| `.github/` | CI/CD workflows and contribution templates |
| `Package.swift` | Host modules, service/guardian executables and Mac tests |
| `config/` | Signing configuration template; personal values stay ignored |
| `project.yml` | Source of truth for the Xcode project |

`packages/` is a repository grouping convention, not an Apple-mandated name. Each package follows the standard `Package.swift`, `Sources/<Target>/` and `Tests/<Target>Tests/` layout. One generated `.xcodeproj` is sufficient; a separate `.xcworkspace` is unnecessary for these local Swift packages.

`main` is the release branch. Work integrates through `dev`; features use `feat_<module>_<purpose>` branches. See the [worktree workflow](docs/development.md#daily-workflow) and [contribution guidelines](CONTRIBUTING.md).

Prefer native capabilities and mature, license-reviewed components. Extract reusable packages from demonstrated shared behavior, not speculative device integrations. Current runtime dependencies and source references are documented in [architecture](docs/architecture.md) and [the reference registry](references/README.md).

## Privacy and distribution

Remote work needs the Mac’s local Codex account; independent local capture needs no model account. Stored text is sensitive user data; see [SECURITY](SECURITY.md). No product open-source license or distribution rights have been selected. Third-party projects retain their own licenses.
