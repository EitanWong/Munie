// Munie modification: add app-managed relay opt-in and authenticated route status.
// FILE: SettingsConnectionCard.swift
// Purpose: Presents paired-computer connection state and connection actions.
// Layer: Settings UI component
// Exports: SettingsConnectionCard
// Depends on: SwiftUI, CodexService connection state, SettingsSupportCards

import SwiftUI

struct SettingsConnectionCard: View {
    @Environment(CodexService.self) private var codex
    @AppStorage(CodexService.hostedRelayPreferenceKey) private var useHostedRelay = false
    @State private var isShowingDisconnectConfirmation = false
    let onEditComputerName: () -> Void

    var body: some View {
        SettingsCard(
            title: "Device",
            footer: keepAwakeFooter
        ) {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                SettingsTrustedComputerCard(
                    presentation: trustedPairPresentation,
                    connectionStatusLabel: connectionStatusLabel,
                    onEditName: onEditComputerName
                )
            } else {
                SettingsInlineMessage(text: "No paired device yet. Scan the QR code from your Mac to connect.")
            }

            if connectionPhaseShowsProgress {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(connectionProgressLabel)
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                }
            }

            if case .retrying(_, let message) = codex.connectionRecoveryState,
               !message.isEmpty {
                SettingsInlineMessage(text: message)
            }

            if let error = codex.lastErrorMessage, !error.isEmpty {
                SettingsInlineMessage(text: error, tint: .red)
            }

            if codex.supportsKeepAwakeWhileBridgeRuns {
                Toggle("Keep device reachable", isOn: keepMacAwakeWhileBridgeRunsBinding)
                    .tint(settingsToggleTintColor)
            }

            if codex.configuredHostedRelayOrigin != nil {
                Toggle("Allow Connections Away from Home", isOn: $useHostedRelay)
                    .tint(settingsToggleTintColor)
                if codex.isConnected {
                    if codex.isUsingHostedRelay {
                        Text("Connected through the managed relay")
                    } else {
                        Text("Connected directly to your Mac")
                    }
                }
            }

            if codex.isConnected {
                SettingsButton("Disconnect", role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    isShowingDisconnectConfirmation = true
                }
            } else if codex.hasTrustedMacReconnectCandidate {
                SettingsButton("Forget Pair", role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    codex.forgetTrustedMac()
                }
            }
        }
        .onChange(of: useHostedRelay) { _, enabled in
            if !enabled, codex.isUsingHostedRelay || codex.managedRelayAttemptID != nil {
                Task { await codex.disconnect(preserveReconnectIntent: false) }
            }
        }
        .confirmationDialog("Disconnect from this Mac?", isPresented: $isShowingDisconnectConfirmation) {
            Button("Disconnect", role: .destructive) {
                disconnectRelay()
            }
        } message: {
            Text("Your pairing stays saved so you can reconnect later.")
        }
    }

    private var keepAwakeFooter: String? {
        guard codex.supportsKeepAwakeWhileBridgeRuns else { return nil }

        if codex.keepMacAwakeWhileBridgeRuns {
            return "Keeps your Mac reachable while the bridge is running. Best while charging."
        }

        if !codex.isConnected {
            return "Preference is saved on this iPhone and syncs when the bridge reconnects."
        }

        return nil
    }

    private var keepMacAwakeWhileBridgeRunsBinding: Binding<Bool> {
        Binding(
            get: { codex.keepMacAwakeWhileBridgeRuns },
            set: { nextValue in
                codex.setKeepMacAwakeWhileBridgeRunsPreference(nextValue)
                Task { @MainActor in
                    await codex.syncBridgeKeepMacAwakePreferenceIfNeeded(showFailureInUI: true)
                }
            }
        )
    }

    private var connectionPhaseShowsProgress: Bool {
        switch codex.connectionPhase {
        case .connecting, .loadingChats, .syncing:
            return true
        case .offline, .connected:
            return false
        }
    }

    private var connectionStatusLabel: String {
        switch codex.connectionPhase {
        case .offline:
            return "Offline"
        case .connecting:
            return "Connecting"
        case .loadingChats:
            return "Loading"
        case .syncing:
            return "Syncing"
        case .connected:
            return "Connected"
        }
    }

    private var connectionProgressLabel: String {
        switch codex.connectionPhase {
        case .connecting:
            return "Connecting to relay…"
        case .loadingChats:
            return "Loading chats…"
        case .syncing:
            return "Syncing workspace…"
        case .offline, .connected:
            return ""
        }
    }

    private func disconnectRelay() {
        Task { @MainActor in
            await codex.disconnect()
            codex.clearSavedRelaySession()
        }
    }
}
