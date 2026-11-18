// Munie modification: backgrounding discards capture; never uploads audio automatically.
// FILE: VoiceInputCoordinator.swift
// Purpose: Owns shared voice recording, transcription, lifecycle, and recovery state for turn composers.
// Layer: View Support
// Exports: VoiceInputCoordinator
// Depends on: Combine, SwiftUI, CodexService, GPTVoiceTranscriptionManager

import Combine
import Foundation
import SwiftUI

private func codexLogVoiceInput(_ message: String) {
    print("[VOICE] \(message)")
}

// Keeps capture lifecycle tests independent of microphone permission and hardware.
@MainActor
struct VoiceCaptureOperations {
    var start: () async throws -> Void
    var stop: (Bool) throws -> GPTVoiceRecordingClip?
    var cancel: () -> Void
    var resetMetering: () -> Void

    init(
        start: @escaping () async throws -> Void,
        stop: @escaping (Bool) throws -> GPTVoiceRecordingClip?,
        cancel: @escaping () -> Void,
        resetMetering: @escaping () -> Void
    ) {
        self.start = start
        self.stop = stop
        self.cancel = cancel
        self.resetMetering = resetMetering
    }

    init(recorder: GPTVoiceTranscriptionManager) {
        start = { try await recorder.startRecording() }
        stop = { try recorder.stopRecording(preferM4A: $0) }
        cancel = { recorder.cancelRecording() }
        resetMetering = { recorder.resetMeteringState() }
    }
}

@MainActor
final class VoiceInputCoordinator: ObservableObject {
    // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
    nonisolated deinit {}

    @Published private(set) var isRecording = false
    @Published private(set) var isPreflighting = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var recoveryReason: CodexVoiceFailureReason?
    @Published var isShowingSetupSheet = false

    let transcriptionManager: GPTVoiceTranscriptionManager
    private let capture: VoiceCaptureOperations
    private var isSceneActive = true

    private var preflightGeneration = 0
    private var preflightTask: Task<Void, Never>?
    private var captureGeneration: Int?
    private var operationGeneration = 0
    private var transcriptionTask: Task<Void, Never>?
    private var hasTriggeredAutoStop = false
    private var meteringCancellable: AnyCancellable?

    init(capture: VoiceCaptureOperations? = nil) {
        let recorder = GPTVoiceTranscriptionManager()
        transcriptionManager = recorder
        self.capture = capture ?? VoiceCaptureOperations(recorder: recorder)
        meteringCancellable = transcriptionManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isInputActive: Bool {
        isRecording || isPreflighting || isTranscribing
    }

    var audioLevels: [CGFloat] {
        transcriptionManager.audioLevels
    }

    var recordingDuration: TimeInterval {
        transcriptionManager.recordingDuration
    }

    // Mirrors the mic CTA state so composers can swap between ready, record, and stop.
    func buttonPresentation(isConnected: Bool) -> TurnComposerVoiceButtonPresentation {
        TurnVoiceButtonPresentationBuilder.presentation(
            isTranscribing: isTranscribing,
            isPreflighting: isPreflighting,
            isRecording: isRecording,
            isConnected: isConnected
        )
    }

    func clearRecovery() {
        recoveryReason = nil
    }

    func clearReconnectRecoveryIfNeeded() {
        if recoveryReason == .reconnectRequired {
            clearRecovery()
        }
    }

    // Switches the mic button between login, recording, and transcription states.
    func handleButtonTap(
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) {
        guard isSceneActive else { return }
        codexLogVoiceInput(
            "button tapped recording=\(isRecording) preflighting=\(isPreflighting) transcribing=\(isTranscribing) connected=\(codex.isConnected)"
        )
        if isTranscribing {
            return
        }

        if isRecording {
            beginStopTranscription(codex: codex, onTranscript: onTranscript, onDismissInput: onDismissInput)
            return
        }

        guard !isPreflighting, preflightTask == nil else { return }
        // Bind before enqueueing, so a same-turn cancel/disappearance invalidates this start.
        preflightGeneration += 1
        let currentGeneration = preflightGeneration
        preflightTask = Task { @MainActor [weak self] in
            await self?.startRecordingIfReady(
                generation: currentGeneration, codex: codex, onDismissInput: onDismissInput)
        }
    }

    // Auto-stops a clip just before the hard validation limit.
    func handleRecordingDuration(
        _ duration: TimeInterval,
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) {
        guard isRecording,
              !isTranscribing,
              !hasTriggeredAutoStop,
              duration >= voiceAutoStopThreshold else {
            return
        }

        hasTriggeredAutoStop = true
        beginStopTranscription(codex: codex, onTranscript: onTranscript, onDismissInput: onDismissInput)
    }

    // Leaving the active scene abandons capture without an automatic upload.
    func handleScenePhaseChange(
        _ phase: ScenePhase,
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) {
        isSceneActive = phase == .active
        guard phase != .active else {
            return
        }

        cancelInputIfNeeded()
    }

    // Disappearing outside the background path treats voice input as abandoned and cancels it.
    func handleViewDisappear(
        scenePhase: ScenePhase,
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) {
        guard scenePhase == .background else {
            cancelInputIfNeeded()
            clearRecovery()
            return
        }

        handleScenePhaseChange(
            scenePhase,
            codex: codex,
            onTranscript: onTranscript,
            onDismissInput: onDismissInput
        )
    }

    // Resets UI state when iOS invalidates the mic route underneath active recording.
    func handleCaptureInvalidation(codex: CodexService) {
        guard isRecording || isPreflighting else {
            return
        }

        cancelTranscriptionIfNeeded()
        invalidatePendingPreflight()
        capture.cancel()
        captureGeneration = nil
        isRecording = false
        isPreflighting = false
        hasTriggeredAutoStop = false
        capture.resetMetering()
        presentRecovery(for: .recorderUnavailable, codex: codex)
    }

    // User-initiated cancel clears the full voice flow, including a stop/upload race.
    func cancelInputIfNeeded() {
        cancelTranscriptionIfNeeded()
        invalidatePendingPreflight()
        cancelRecordingIfNeeded()
    }

    func startVoiceLoginOnMac(codex: CodexService) {
        Task { @MainActor [weak self] in
            do {
                try await codex.startOrResumeGPTLoginOnMac()
                self?.presentRecovery(for: .voiceSyncInProgress, codex: codex)
            } catch {
                self?.presentRecovery(for: error, codex: codex)
            }
        }
    }

    private func beginStopTranscription(
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) {
        guard isRecording, !isTranscribing else {
            return
        }

        hasTriggeredAutoStop = false
        isTranscribing = true
        operationGeneration += 1
        let currentGeneration = operationGeneration
        transcriptionTask?.cancel()
        // Re-warm right before upload so the provider connection overlaps clip prep and relay transfer.
        codex.prewarmVoiceTranscription()
        codexLogVoiceInput("stop requested; starting transcription pipeline")
        transcriptionTask = Task { @MainActor [weak self] in
            await self?.stopTranscription(
                operationGeneration: currentGeneration,
                codex: codex,
                onTranscript: onTranscript,
                onDismissInput: onDismissInput
            )
        }
    }

    private func stopTranscription(
        operationGeneration: Int,
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) async {
        defer {
            if isOperationCurrent(operationGeneration) {
                isTranscribing = false
                transcriptionTask = nil
            }
        }

        do {
            guard isOperationCurrent(operationGeneration), !Task.isCancelled else {
                return
            }
            codexLogVoiceInput("stopping recorder")
            captureGeneration = nil
            guard let clip = try capture.stop(codex.prefersM4AVoiceTranscription) else {
                if isOperationCurrent(operationGeneration) {
                    isRecording = false
                    capture.resetMetering()
                    codexLogVoiceInput("stop produced no audio clip")
                    presentRecovery(for: .recorderUnavailable, codex: codex)
                }
                return
            }

            defer {
                try? FileManager.default.removeItem(at: clip.url)
            }

            isRecording = false
            capture.resetMetering()
            codexLogVoiceInput(
                "transcription upload starting duration=\(String(format: "%.1f", clip.durationSeconds))s bytes=\(clip.byteCount)"
            )
            let transcript = try await VoiceTranscriptionBackgroundTask.run {
                try await codex.transcribeVoiceAudioFile(
                    at: clip.url,
                    durationSeconds: clip.durationSeconds,
                    mimeType: clip.mimeType
                )
            }
            guard isOperationCurrent(operationGeneration), !Task.isCancelled else {
                return
            }

            clearRecovery()
            codexLogVoiceInput("transcription succeeded chars=\(transcript.count)")
            onTranscript(transcript)
            onDismissInput()
        } catch {
            guard isOperationCurrent(operationGeneration), !Task.isCancelled else {
                return
            }
            isRecording = false
            capture.resetMetering()
            codexLogVoiceInput("transcription failed: \(codex.classifyVoiceFailure(error))")
            presentRecovery(for: error, codex: codex)
        }
    }

    // Starts microphone capture; auth resolves only after the user stops recording.
    private func startRecordingIfReady(
        generation currentGeneration: Int,
        codex: CodexService,
        onDismissInput: @escaping @MainActor () -> Void
    ) async {
        defer {
            if isPreflightCurrent(currentGeneration) {
                isPreflighting = false
                preflightTask = nil
            }
        }
        guard isPreflightCurrent(currentGeneration), !Task.isCancelled,
              isSceneActive, !isPreflighting, !isRecording, !isTranscribing else {
            return
        }

        guard codex.isConnected else {
            presentRecovery(for: .reconnectRequired, codex: codex)
            return
        }

        clearRecovery()
        codex.lastErrorMessage = nil
        hasTriggeredAutoStop = false
        isPreflighting = true
        onDismissInput()

        do {
            guard isPreflightCurrent(currentGeneration) else {
                return
            }
            // Warm bridge auth + provider TLS while the user is still speaking.
            codex.prewarmVoiceTranscription()
            captureGeneration = currentGeneration
            try await capture.start()
            guard isPreflightCurrent(currentGeneration), !Task.isCancelled else {
                // Late work owns cleanup only until a newer capture has acquired the recorder.
                if captureGeneration == currentGeneration {
                    capture.cancel()
                    captureGeneration = nil
                }
                return
            }
            isRecording = true
            onDismissInput()
        } catch {
            guard isPreflightCurrent(currentGeneration) else {
                return
            }
            presentRecovery(for: error, codex: codex)
        }
    }

    private func cancelRecordingIfNeeded() {
        guard isRecording else {
            return
        }

        capture.cancel()
        captureGeneration = nil
        isRecording = false
        hasTriggeredAutoStop = false
    }

    private func cancelTranscriptionIfNeeded() {
        guard isTranscribing || transcriptionTask != nil else {
            return
        }

        operationGeneration += 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
    }

    private func invalidatePendingPreflight() {
        preflightGeneration += 1
        preflightTask?.cancel()
        preflightTask = nil
        guard isPreflighting else {
            return
        }

        isPreflighting = false
        capture.cancel()
        hasTriggeredAutoStop = false
    }

    private func presentRecovery(for error: Error, codex: CodexService) {
        presentRecovery(for: codex.classifyVoiceFailure(error), codex: codex)
    }

    private func presentRecovery(for reason: CodexVoiceFailureReason, codex: CodexService? = nil) {
        recoveryReason = reason
        codex?.lastErrorMessage = nil
    }

    private var voiceAutoStopThreshold: TimeInterval {
        max(0, CodexVoiceTranscriptionPreflight.maxDurationSeconds - 0.25)
    }

    private func isPreflightCurrent(_ generation: Int) -> Bool {
        generation == preflightGeneration
    }

    private func isOperationCurrent(_ generation: Int) -> Bool {
        generation == operationGeneration
    }
}
