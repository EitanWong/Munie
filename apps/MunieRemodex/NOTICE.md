# Munie source adoption

Source: https://github.com/Emanuele-web04/remodex

Pinned revision: `c06dcb16a7059603a41e26a2cb4a81b6d4b5514d`.

Copyright 2025–2026 Emanuele Di Pietro. The copied Swift source is licensed under Apache-2.0; see LICENSE. Modified files carry a Munie modification notice. Unmodified code retains the upstream architecture and behavior.

This target adopts the full iOS Models/Services/Views source, including timeline, Markdown, code, command progress, approvals, history, replay and reconnect. The tests are retained against the renamed module.

Munie changes remove RevenueCat billing and its free-send limit, use Munie identity and Apple system fonts/symbols, omit upstream branding and font assets, and disable the native Ghostty renderer because the binary provenance and notices are not established. Widget source is retained but the extension is not yet embedded.

The initial vendor target preserves upstream Swift 5 mode with MainActor default isolation and iOS 18.6. This is a bounded source-adoption exception, not a claim of Swift 6 migration, iPad adaptation, bilingual completion, physical acceptance or notification delivery.

Munie adds English and Simplified Chinese catalogs for the main pairing, project, composer, voice, approval, connection and notification controls. Untranslated advanced upstream UI and native error text remain migration work. Voice recording is explicitly started, capped at 30 seconds and discarded on background or cancellation; transcription still uses the Mac bridge/ChatGPT account. This differs from the earlier on-device Speech implementation. Mermaid displays the source fallback because its bundled JavaScript was not adopted. Hardware audio, system entry and notification delivery require their own acceptance.
