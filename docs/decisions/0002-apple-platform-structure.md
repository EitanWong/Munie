# ADR 0002 — Apple-native platform structure and agent guidance

Status: Accepted, 2026-11-17.

## Context

The iOS-only source directory and manifest did not express the intended Apple ecosystem scope. Agents also needed a short maintained entry point to Apple engineering and Human Interface Guidelines without loading the historical research archive.

## Decision

Use one native multi-destination `Munie` application target for iOS/iPadOS, macOS, tvOS and visionOS, and a separate standalone `MunieWatch` target. This follows Apple's supported target configuration. Keep shared app presentation and resources in `apps/Munie`, Watch interaction in `apps/MunieWatch`, and actual platform-independent domain/storage in the existing `packages/MunieCore` Swift package. Declare deployment floors on every platform. Do not add empty platform packages or a redundant workspace.

Keep the checksum-pinned XcodeGen tool and `project.yml` as the configuration source. It produces an ordinary Xcode project and shared schemes; it is not an app runtime dependency. `packages/` is a repository choice; `Package.swift`, `Sources` and `Tests` inside each package are the SwiftPM convention.

Add a progressive agent index: root contract → task routing → relevant Apple engineering/HIG rules and platform acceptance → official sources and ADRs. Distinguish mandatory platform/API requirements, Apple design guidance and stricter Munie conventions. Preserve existing security and PR lifecycle rules.

## Alternatives

Separate app targets and duplicated sources for every OS would complicate common changes without a current signing/entitlement need. A single target including watchOS is unsupported. Catalyst or compatibility mode would not provide the requested native Mac/visionOS build boundary. A UI package is unnecessary for sources already shared directly by app targets.

## Consequences and review triggers

Build all five SDK families in local checks and CI; iPadOS shares the iOS device family. Build success is not hardware, accessibility, HIG or distribution acceptance. Mac uses a single window until draft state can be owned per window. Watch data remains local and independent. tvOS stores captures in purgeable cache and warns in the UI; durable TV records require a future reviewed synchronization/storage design. tvOS and visionOS native distribution artwork remains a release gate. Revisit target separation only for real entitlement, extension, release or platform-UX needs.

The local UI uses Apple components rather than adding a third-party UI framework; existing Chums research remains a reference for future Watch connectivity, not adopted code. No new runtime dependency or source license is introduced. Official source links and XcodeGen's MIT attribution are in the [guidance registry](../../references/apple-platform-guidance.md).
