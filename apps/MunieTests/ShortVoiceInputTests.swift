#if os(iOS)
  import Foundation
  import Speech
  import Testing

  @testable import Munie

  @MainActor
  struct ShortVoiceInputTests {
    @Test func deniedMicrophoneDoesNotRequestSpeechOrStartRecording() async {
      var speechRequests = 0
      let voice = ShortVoiceInput(
        requestMicrophone: { false },
        requestSpeech: {
          speechRequests += 1
          return .authorized
        })
      voice.transcript = "Keep existing text"
      await voice.start()
      #expect(speechRequests == 0)
      #expect(!voice.isRecording)
      #expect(!voice.isRequestingPermission)
      #expect(voice.transcript == "Keep existing text")
      #expect(voice.errorMessage != nil)
    }

    @Test func deniedSpeechPreservesTextWithoutStartingRecording() async {
      let voice = ShortVoiceInput(requestMicrophone: { true }, requestSpeech: { .denied })
      voice.transcript = "Editable text"
      await voice.start()
      #expect(!voice.isRecording)
      #expect(!voice.isRequestingPermission)
      #expect(voice.transcript == "Editable text")
      #expect(voice.errorMessage != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledMicrophonePromptCannotStartSpeechOrResumeCapture() async {
      let gate = VoicePermissionGate<Bool>()
      var speechRequests = 0
      let voice = ShortVoiceInput(
        requestMicrophone: { await gate.request() },
        requestSpeech: {
          speechRequests += 1
          return .authorized
        })
      let operation = Task { await voice.start() }
      await gate.waitUntilRequested()
      #expect(voice.isRequestingPermission)
      voice.cancel()
      gate.finish(true)
      await operation.value
      #expect(speechRequests == 0)
      #expect(!voice.isRecording)
      #expect(!voice.isRequestingPermission)
      #expect(!voice.isFinishing)
    }

    @Test(.timeLimit(.minutes(1)))
    func interruptedSpeechPromptCannotResumeCaptureAndRepeatedStartDoesNotPromptAgain() async {
      let gate = VoicePermissionGate<SFSpeechRecognizerAuthorizationStatus>()
      var microphoneRequests = 0
      let voice = ShortVoiceInput(
        requestMicrophone: {
          microphoneRequests += 1
          return true
        },
        requestSpeech: { await gate.request() })
      let operation = Task { await voice.start() }
      await gate.waitUntilRequested()
      await voice.start()
      #expect(microphoneRequests == 1)
      voice.interrupt()
      gate.finish(.authorized)
      await operation.value
      #expect(!voice.isRecording)
      #expect(!voice.isRequestingPermission)
      #expect(!voice.isFinishing)
      #expect(voice.errorMessage != nil)
    }
  }

  /// An explicit arrival barrier makes permission cancellation races deterministic.
  @MainActor
  private final class VoicePermissionGate<Value: Sendable> {
    private var result: CheckedContinuation<Value, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func request() async -> Value {
      await withCheckedContinuation { continuation in
        result = continuation
        arrival?.resume()
        arrival = nil
      }
    }

    func waitUntilRequested() async {
      if result != nil { return }
      await withCheckedContinuation { arrival = $0 }
    }

    func finish(_ value: Value) {
      result?.resume(returning: value)
      result = nil
    }
  }
#endif
