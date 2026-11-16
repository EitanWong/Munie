# ADR 0001: Native frontend with a narrow reusable core

Date: 2026-11-17. Status: accepted for the project foundation.

## Context

Munie is a personal Apple-device assistant frontend, not a Codex-only remote terminal. Prior research favors quick capture and reliable continuation as a small learnable starting point. The owner will use it personally before an invited beta. Device entry points and remote harnesses have different platform and distribution constraints.

## Decision

Own a SwiftUI iPhone/iPad app and a Foundation-only Swift 6 package for real shared capture/storage behavior. Start with versioned atomic local files and a replaceable async store contract. Generate the Xcode project from `project.yml`. Keep researched source checkouts in a single ignored registry location with pinned commits and license records.

Develop through `dev`, with `feat_` branches and sibling worktrees; release through reviewed PRs to `main`. Use focused subagent ownership and integrate only after review and meaningful validation.

## Alternatives and consequences

- Forking a Codex-specific client gives faster remote coding features but ties frontend identity and data flow to an execution harness. Keep such clients as adapter references.
- A cross-platform app could reuse more UI, but native entry points and Apple interaction are the current product focus.
- A database or generic plugin framework may become useful. Neither is required to prove the first local capture loop; adding them now increases migration and maintenance surface.

This decision does not settle the future task protocol, model provider, remote hosting, Watch/glasses SDK or product license. Revisit storage for demonstrated indexing, scale, multi-process or synchronization requirements; revisit package boundaries when a second real consumer exists.
