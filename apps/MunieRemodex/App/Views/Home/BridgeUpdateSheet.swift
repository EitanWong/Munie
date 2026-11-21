// Munie modification: self-hosted source fork; see ../NOTICE.md and LICENSE.
// FILE: BridgeUpdateSheet.swift
// Purpose: Guides compatible Mac/iPhone app updates without developer commands.
// Layer: View
// Exports: BridgeUpdateSheet
// Depends on: SwiftUI, CodexBridgeUpdatePrompt, BridgeUpdatePresentation

import SwiftUI

struct BridgeUpdateSheet: View {
    let prompt: CodexBridgeUpdatePrompt
    let isRetrying: Bool
    let onRetry: () -> Void
    let onScanNewQR: () -> Void
    let onDismiss: () -> Void

    private var presentation: BridgeUpdatePresentation {
        BridgeUpdatePresentation(command: prompt.command)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header

                        updateInstructions
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                }

                actionButtons
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.title)
                .font(AppFont.title3(weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(presentation.message)
                .font(AppFont.body())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Keeps long bridge-version copy scrollable while the recovery actions stay reachable.
    private var updateInstructions: some View {
        Text(presentation.guidance)
            .font(AppFont.body())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: onRetry) {
                HStack(spacing: 8) {
                    if isRetrying {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(isRetrying ? String(localized: "Reconnecting...") : String(localized: "Try Again"))
                        .font(AppFont.body(weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isRetrying)

            Button(String(localized: "Find My Mac"), action: onScanNewQR)
                .font(AppFont.body(weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                )
                .buttonStyle(.plain)

            Button(String(localized: "Not Now"), role: .cancel, action: onDismiss)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
    }
}
