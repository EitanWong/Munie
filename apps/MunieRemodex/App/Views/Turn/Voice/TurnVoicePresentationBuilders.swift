// Munie modification: self-hosted source fork; see ../NOTICE.md and LICENSE.
// FILE: TurnVoicePresentationBuilders.swift
// Purpose: Maps voice recording/auth state into composer and recovery UI presentations.
// Layer: View Support
// Exports: TurnVoiceButtonPresentationBuilder, TurnVoiceRecoveryPresentationBuilder
// Depends on: SwiftUI, TurnComposerVoiceButtonPresentation, ConnectionRecoverySnapshot

import SwiftUI

enum TurnVoiceButtonPresentationBuilder {
    static func presentation(
        isTranscribing: Bool,
        isPreflighting: Bool,
        isRecording: Bool,
        isConnected: Bool
    ) -> TurnComposerVoiceButtonPresentation {
        if isTranscribing {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "waveform",
                foregroundColor: Color(.secondaryLabel),
                backgroundColor: Color(.systemGray5),
                accessibilityLabel: String(localized: "Transcribing voice note"),
                isDisabled: true,
                showsProgress: true,
                hasCircleBackground: true
            )
        }

        if isPreflighting {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "hourglass",
                foregroundColor: Color(.secondaryLabel),
                backgroundColor: Color(.systemGray5),
                accessibilityLabel: String(localized: "Preparing microphone"),
                isDisabled: true,
                showsProgress: true,
                hasCircleBackground: true
            )
        }

        if isRecording {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "stop.fill",
                foregroundColor: Color(.systemBackground),
                backgroundColor: Color(.systemRed),
                accessibilityLabel: String(localized: "Stop voice recording"),
                isDisabled: false,
                showsProgress: false,
                hasCircleBackground: true
            )
        }

        return TurnComposerVoiceButtonPresentation(
            systemImageName: "mic",
            foregroundColor: Color.primary,
            backgroundColor: .clear,
            accessibilityLabel: isConnected ? String(localized: "Start voice transcription") : String(localized: "Reconnect for voice transcription"),
            isDisabled: false,
            showsProgress: false,
            hasCircleBackground: false
        )
    }
}

enum TurnVoiceRecoveryPresentationBuilder {
    static func presentation(for reason: CodexVoiceFailureReason) -> VoiceRecoveryPresentation {
        switch reason {
        case .reconnectRequired:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: String(localized: "Reconnect to your device to use voice mode."),
                    detail: String(localized: "Keep the Munie bridge running on your paired device, then try the microphone again."),
                    status: .interrupted,
                    trailingStyle: .action(String(localized: "Reconnect"))
                ),
                action: .reconnect
            )
        case .bridgeSessionUnsupported:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: String(localized: "This bridge session does not support voice mode yet."),
                    detail: String(localized: "Restart Munie on your device, then reconnect this iPhone. If it still happens, update Munie on your device and pair again."),
                    status: .actionRequired,
                    trailingStyle: .action(String(localized: "Reconnect"))
                ),
                action: .reconnect
            )
        case .macLoginRequired:
            return macLoginPresentation(
                summary: String(localized: "Set up ChatGPT on your device to use voice mode."),
                detail: String(localized: "Sign in to ChatGPT on the paired device, then try again.")
            )
        case .macReauthenticationRequired:
            return macLoginPresentation(
                summary: String(localized: "Voice mode needs fresh ChatGPT auth on your device."),
                detail: String(localized: "Sign in to ChatGPT again on the paired device, then retry voice mode here.")
            )
        case .providerAuthenticationRejected(let message):
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return macLoginPresentation(
                summary: trimmedMessage.isEmpty
                    ? String(localized: "Voice transcription auth was rejected.")
                    : trimmedMessage,
                detail: String(localized: "Refresh ChatGPT login on the paired device, then retry voice mode here.")
            )
        case .voiceSyncInProgress:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: String(localized: "Voice mode is still syncing from your device."),
                    detail: String(localized: "Keep the bridge connected for a moment, then try again."),
                    status: .syncing,
                    trailingStyle: .progress
                ),
                action: .none
            )
        case .chatGPTRequired:
            return setupHelpPresentation(
                summary: String(localized: "Voice mode needs ChatGPT on your paired device."),
                detail: String(localized: "Sign in to ChatGPT on the paired device, then retry voice mode here.")
            )
        case .microphonePermissionRequired:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: String(localized: "Microphone access is off for Munie."),
                    detail: String(localized: "Open iPhone Settings, allow Microphone for Munie, then try recording again."),
                    status: .actionRequired,
                    trailingStyle: .action(String(localized: "Open Settings"))
                ),
                action: .openSystemSettings
            )
        case .microphoneUnavailable:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: String(localized: "No microphone input is available right now."),
                    detail: String(localized: "Check that another app is not holding the microphone, then try again."),
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        case .recorderUnavailable:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: String(localized: "Munie could not start the recorder."),
                    detail: String(localized: "Close other audio-heavy apps, then try voice mode again."),
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        case .generic(let message):
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: String(localized: "Voice Mode"),
                    summary: message,
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        }
    }

    private static func setupHelpPresentation(
        summary: String,
        detail: String
    ) -> VoiceRecoveryPresentation {
        VoiceRecoveryPresentation(
            snapshot: snapshot(
                summary: summary,
                detail: detail,
                status: .actionRequired,
                trailingStyle: .action(String(localized: "How To Fix"))
            ),
            action: .showSetupHelp
        )
    }

    private static func macLoginPresentation(
        summary: String,
        detail: String
    ) -> VoiceRecoveryPresentation {
        VoiceRecoveryPresentation(
            snapshot: snapshot(
                summary: summary,
                detail: detail,
                status: .actionRequired,
                trailingStyle: .action(String(localized: "Open Login"))
            ),
            action: .openMacLogin
        )
    }

    private static func snapshot(
        summary: String,
        detail: String? = nil,
        status: ConnectionRecoveryStatus,
        trailingStyle: ConnectionRecoveryTrailingStyle
    ) -> ConnectionRecoverySnapshot {
        ConnectionRecoverySnapshot(
            title: String(localized: "Voice Mode"),
            summary: summary,
            detail: detail,
            status: status,
            trailingStyle: trailingStyle
        )
    }
}
