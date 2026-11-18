#if os(iOS)
  import AVFoundation
  import Observation
  import Speech
  import SwiftUI

  @MainActor
  @Observable
  final class ShortVoiceInput {
    private(set) var isRecording = false
    private(set) var isRequestingPermission = false
    private(set) var isFinishing = false
    private(set) var errorMessage: String?
    var transcript = ""

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var deadline: Task<Void, Never>?
    private var finishDeadline: Task<Void, Never>?
    private var generation = UUID()
    private var ownsAudioSession = false
    private let requestMicrophone: @MainActor () async -> Bool
    private let requestSpeech: @MainActor () async -> SFSpeechRecognizerAuthorizationStatus

    init(
      requestMicrophone: @escaping @MainActor () async -> Bool = {
        await AVAudioApplication.requestRecordPermission()
      },
      requestSpeech: @escaping @MainActor () async -> SFSpeechRecognizerAuthorizationStatus = {
        await withCheckedContinuation { continuation in
          SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
      }
    ) {
      self.requestMicrophone = requestMicrophone
      self.requestSpeech = requestSpeech
    }

    func start() async {
      guard !isRecording, !isRequestingPermission, !isFinishing else { return }
      errorMessage = nil
      isRequestingPermission = true
      let operation = UUID()
      generation = operation
      defer { if generation == operation { isRequestingPermission = false } }
      let microphone = await requestMicrophone()
      guard generation == operation, !Task.isCancelled else { return }
      guard microphone else {
        errorMessage = remoteString(
          "Microphone and speech access are needed for voice. You can type instead.")
        return
      }
      let speech = await requestSpeech()
      guard generation == operation, !Task.isCancelled else { return }
      guard speech == .authorized else {
        errorMessage = remoteString(
          "Microphone and speech access are needed for voice. You can type instead.")
        return
      }
      guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable,
        recognizer.supportsOnDeviceRecognition
      else {
        errorMessage = remoteString(
          "On-device speech is unavailable for this language. You can type instead.")
        return
      }
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        ownsAudioSession = true
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
          throw VoiceError.inputUnavailable
        }
        self.engine = engine
        self.request = request
        transcript = ""
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
          request.append(buffer)
        }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
          let text = result?.bestTranscription.formattedString
          let final = result?.isFinal == true
          let failed = error != nil
          Task { @MainActor [weak self] in
            guard let self, self.generation == operation else { return }
            if let text { self.transcript = text }
            if final || failed {
              self.releaseAudio()
              self.isFinishing = false
              self.finishDeadline?.cancel()
              self.finishDeadline = nil
              self.recognitionTask = nil
              if failed && self.transcript.isEmpty {
                self.errorMessage = remoteString(
                  "Speech recognition failed. Try again or type your request.")
              }
            }
          }
        }
        engine.prepare()
        try engine.start()
        isRecording = true
        deadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
          guard let self, self.generation == operation else { return }
          self.stop()
        }
      } catch {
        cancel()
        errorMessage = remoteString(
          "Recording could not start. Check the microphone or type instead.")
      }
    }

    func stop() {
      guard isRecording else { return }
      releaseAudio()
      isFinishing = true
      let operation = generation
      finishDeadline = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        guard let self, self.generation == operation else { return }
        self.recognitionTask?.cancel()
        self.recognitionTask = nil
        self.isFinishing = false
      }
    }

    /// Interruptions never restart the microphone. Already recognized text stays editable.
    func interrupt() {
      guard isRecording || isRequestingPermission || isFinishing else { return }
      cancel()
      errorMessage = remoteString(
        "Recording stopped after an interruption. Review the text or start again.")
    }

    func cancel() {
      generation = UUID()
      isRequestingPermission = false
      isFinishing = false
      deadline?.cancel()
      deadline = nil
      finishDeadline?.cancel()
      finishDeadline = nil
      releaseAudio()
      recognitionTask?.cancel()
      recognitionTask = nil
    }

    private func releaseAudio() {
      deadline?.cancel()
      deadline = nil
      if let engine {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
      }
      engine = nil
      request?.endAudio()
      request = nil
      isRecording = false
      guard ownsAudioSession else { return }
      ownsAudioSession = false
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        errorMessage = remoteString(
          "The audio session could not be released. Recording has stopped.")
      }
    }

    private enum VoiceError: Error { case inputUnavailable }
  }

  struct ShortVoiceInputView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var voice = ShortVoiceInput()
    let useText: (String) -> Void

    var body: some View {
      NavigationStack {
        Form {
          Section {
            Text(
              remoteString(
                "Record up to 30 seconds. Recognition stays on this device. Munie saves no audio.")
            )
            .foregroundStyle(.secondary)
            if voice.isRecording {
              Label(remoteString("Recording — stops after 30 seconds"), systemImage: "mic.fill")
                .accessibilityAddTraits(.updatesFrequently)
              Button(remoteString("Stop recording"), systemImage: "stop.fill") { voice.stop() }
                .accessibilityIdentifier("remote.voice.stop")
            } else {
              Button(remoteString("Start recording"), systemImage: "mic.fill") {
                Task { await voice.start() }
              }
              .disabled(voice.isRequestingPermission || voice.isFinishing)
              .accessibilityIdentifier("remote.voice.start")
            }
            if voice.isRequestingPermission || voice.isFinishing { ProgressView() }
          }
          Section(remoteString("Review and correct")) {
            TextEditor(text: $voice.transcript)
              .frame(minHeight: 140)
              .disabled(voice.isRecording || voice.isRequestingPermission || voice.isFinishing)
              .accessibilityLabel(remoteString("Recognized text"))
            Text(
              remoteString(
                "Review the text before adding it to your request. Nothing is submitted automatically."
              )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          if let error = voice.errorMessage { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(remoteString("Short voice input"))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(remoteString("Discard")) {
              voice.cancel()
              dismiss()
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(remoteString("Use text")) {
              useText(voice.transcript)
              voice.cancel()
              dismiss()
            }
            .disabled(
              voice.isRecording || voice.isRequestingPermission || voice.isFinishing
                || voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .background || (phase == .inactive && !voice.isRequestingPermission) {
            voice.interrupt()
          }
        }
        .onReceive(
          NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
        ) { _ in
          voice.interrupt()
        }
        .onReceive(
          NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
        ) { notice in
          let raw = notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
          if let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
            reason != .categoryChange
          {
            voice.interrupt()
          }
        }
        .onDisappear { voice.cancel() }
      }
    }
  }
#endif
