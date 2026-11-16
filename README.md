# Munie

Your personal AI companion, close at hand.

[GitHub](https://github.com/EitanWong/Munie) · [简体中文](README.zh-Hans.md) · [Documentation](docs/README.md) · [Project status](docs/project-status.md)

Munie is an Apple-native frontend for capturing a thought, finding it later, and eventually handing work to an interchangeable AI execution service. The foundation provides local text capture with a native shared app target for iPhone, iPad, Mac, Apple TV and Apple Vision Pro, plus a separate Apple Watch app. Shared code does not imply cross-device synchronization. Remote execution, voice, Watch connectivity and Ray-Ban Meta integration remain future milestones. Apple TV records use purgeable cache storage.

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

## Repository

| Path | Responsibility |
|---|---|
| `apps/Munie/` | Native multi-destination SwiftUI app, shared presentation and resources |
| `apps/MunieWatch/` | Watch-specific interaction in a separate watchOS app target |
| `apps/MunieTests/`, `apps/MunieUITests/` | App unit and iOS UI test targets |
| `packages/MunieCore/` | Reusable capture models, durable storage and core tests |
| `docs/` | Product decisions, architecture, workflow, research and project status |
| `references/` | Pinned third-party registry and ignored source checkouts |
| `scripts/` | Reproducible local and CI automation |
| `.github/` | CI/CD workflows and contribution templates |
| `Package.swift` | Host-side tests for app presentation logic; not a shipping library |
| `config/` | Signing configuration template; personal values stay ignored |
| `project.yml` | Source of truth for the Xcode project |

`packages/` is a repository grouping convention, not an Apple-mandated name. Each package follows the standard `Package.swift`, `Sources/<Target>/` and `Tests/<Target>Tests/` layout. One generated `.xcodeproj` is sufficient; a separate `.xcworkspace` is unnecessary for these local Swift packages.

`main` is the release branch. Work integrates through `dev`; features use `feat_<module>_<purpose>` branches in sibling worktrees. See [CONTRIBUTING](CONTRIBUTING.md).

Prefer native capabilities and mature, license-reviewed components. Extract reusable packages from demonstrated shared behavior, not speculative device integrations. Current runtime dependencies and source references are documented in [architecture](docs/architecture.md) and [the reference registry](references/README.md).

## Privacy and distribution

The local capture foundation does not require a model account or a server. Stored text is sensitive user data; see [SECURITY](SECURITY.md). No product open-source license or distribution rights have been selected. Third-party projects retain their own licenses.
