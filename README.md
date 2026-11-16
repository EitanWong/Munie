# Munie

Your personal AI companion, close at hand.

[简体中文](README.zh-Hans.md) · [Documentation](docs/README.md) · [Project status](docs/project-status.md)

Munie is an Apple-native frontend for capturing a thought, finding it later, and eventually handing work to an interchangeable AI execution service. The first foundation focuses on reliable local text capture on iPhone and iPad. Remote execution, voice, Apple Watch, and Ray-Ban Meta integration are future milestones; they are not active capabilities.

## Start developing

Requirements: macOS and Xcode with Swift 6 and the iOS 18+ SDK. Bootstrap downloads checksum-pinned XcodeGen 2.46.0 into ignored `.tools/`. Simulator tests also require an installed iPhone simulator runtime.

```sh
./scripts/bootstrap.sh
open Munie.xcodeproj
./scripts/check.sh
./scripts/test-ios.sh
```

Select your own signing team and unique bundle identifier before installing on a device. The generated Xcode project is ignored; edit `project.yml` instead. See [development](docs/development.md) and [testing](docs/testing.md) for individual checks and environment limits.

## Repository

| Path | Responsibility |
|---|---|
| `apps/ios/` | SwiftUI iPhone/iPad app, presentation, localization and app tests |
| `packages/MunieCore/` | Reusable capture models, durable storage and core tests |
| `docs/` | Product decisions, architecture, workflow, research and project status |
| `references/` | Pinned third-party registry and ignored source checkouts |
| `scripts/` | Reproducible local and CI automation |
| `.github/` | CI/CD workflows and contribution templates |
| `project.yml` | Source of truth for the Xcode project |

`main` is the release branch. Work integrates through `dev`; features use `feat_<module>_<purpose>` branches in sibling worktrees. See [CONTRIBUTING](CONTRIBUTING.md).

Prefer native capabilities and mature, license-reviewed components. Extract reusable packages from demonstrated shared behavior, not speculative device integrations. Current runtime dependencies and source references are documented in [architecture](docs/architecture.md) and [the reference registry](references/README.md).

## Privacy and distribution

The local capture foundation does not require a model account or a server. Stored text is sensitive user data; see [SECURITY](SECURITY.md). No product open-source license or distribution rights have been selected. Third-party projects retain their own licenses.
