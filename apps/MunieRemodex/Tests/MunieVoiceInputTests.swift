import Foundation
import SwiftUI
import XCTest

@testable import MunieRemodex

@MainActor
final class MunieVoiceInputTests: XCTestCase {
  private static var retainedServices: [CodexService] = []

  override func tearDown() async throws {
    await MunieTestServiceLifecycle.finish(Self.retainedServices)
    Self.retainedServices.removeAll()
    try await super.tearDown()
  }

  func testPreflightAcceptsThirtySecondsAndRejectsAnyLongerClip() {
    XCTAssertNoThrow(
      try CodexVoiceTranscriptionPreflight(byteCount: 2_048, durationSeconds: 30).validate())
    for duration in [30.000_001, 31, 150] {
      XCTAssertThrowsError(
        try CodexVoiceTranscriptionPreflight(byteCount: 2_048, durationSeconds: duration).validate()
      ) { error in
        XCTAssertEqual(error.localizedDescription, "Voice clips must be 30 seconds or less.")
      }
    }
  }

  func testPreflightRejectsNonfiniteAndEmptyDurations() {
    for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
      XCTAssertThrowsError(
        try CodexVoiceTranscriptionPreflight(byteCount: 2_048, durationSeconds: duration).validate()
      ) { error in
        XCTAssertEqual(error.localizedDescription, "Voice clips must include recorded audio.")
      }
    }
  }

  func testOverLimitClipIsRejectedBeforeReadingFileOrCallingBridge() async {
    let service = makeService()
    var methods: [String] = []
    service.requestTransportOverride = { method, _ in
      methods.append(method)
      throw CodexServiceError.disconnected
    }
    do {
      _ = try await service.transcribeVoiceAudioFile(
        at: URL(fileURLWithPath: "/nonexistent/munie-voice-fixture.wav"), durationSeconds: 31)
      XCTFail("An over-limit clip must fail before file preparation")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Voice clips must be 30 seconds or less.")
    }
    XCTAssertTrue(methods.isEmpty)
  }

  func testRecordingAutoStopsOnceAtShortClipBoundaryAndDeliversEditableText() async throws {
    let service = makeService()
    let capture = CaptureFixture()
    let clip = try makeClip(duration: 29.75)
    defer { try? FileManager.default.removeItem(at: clip.url) }
    capture.clip = clip
    let coordinator = makeCoordinator(capture)
    var transcripts: [String] = []
    var uploadedDuration: Int?
    var uploadCount = 0
    service.requestTransportOverride = { method, params in
      if method == "voice/transcribe" {
        uploadCount += 1
        uploadedDuration = params?.objectValue?["durationMs"]?.intValue
      } else {
        XCTAssertEqual(method, "voice/prewarm")
      }
      return self.response(text: "editable draft")
    }

    coordinator.handleButtonTap(
      codex: service, onTranscript: { transcripts.append($0) }, onDismissInput: {})
    await waitUntil { coordinator.isRecording }
    coordinator.handleRecordingDuration(
      29.74, codex: service, onTranscript: { transcripts.append($0) }, onDismissInput: {})
    XCTAssertEqual(capture.stopCount, 0)
    XCTAssertTrue(coordinator.isRecording)
    for duration in [29.75, 30, 30.25] {
      coordinator.handleRecordingDuration(
        duration, codex: service, onTranscript: { transcripts.append($0) }, onDismissInput: {})
    }
    await waitUntil { !coordinator.isInputActive }

    XCTAssertEqual(capture.stopCount, 1)
    XCTAssertEqual(uploadCount, 1)
    XCTAssertEqual(uploadedDuration, 29_750)
    XCTAssertEqual(transcripts, ["editable draft"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: clip.url.path))
  }

  func testInactiveAndBackgroundDiscardRecordingWithoutPreparingOrUploadingClip() async {
    for phase in [ScenePhase.inactive, .background] {
      let service = makeService()
      let capture = CaptureFixture()
      let coordinator = makeCoordinator(capture)
      var transcripts: [String] = []
      var methods: [String] = []
      service.requestTransportOverride = { method, _ in
        methods.append(method)
        return self.response(text: "must not arrive")
      }
      coordinator.handleButtonTap(
        codex: service, onTranscript: { transcripts.append($0) }, onDismissInput: {})
      await waitUntil { coordinator.isRecording }

      coordinator.handleScenePhaseChange(
        phase, codex: service, onTranscript: { transcripts.append($0) }, onDismissInput: {})
      await settleTasks()

      XCTAssertFalse(coordinator.isInputActive)
      XCTAssertEqual(capture.cancelCount, 1)
      XCTAssertEqual(capture.stopCount, 0)
      XCTAssertFalse(methods.contains("voice/transcribe"))
      XCTAssertTrue(transcripts.isEmpty)
    }
  }

  func testBackgroundBeforeQueuedStartPreventsMicrophoneStartup() async {
    let service = makeService()
    let capture = CaptureFixture()
    let coordinator = makeCoordinator(capture)
    service.requestTransportOverride = { _, _ in
      XCTFail("A start abandoned before its task runs must not warm or upload voice")
      return self.response(text: "unused")
    }
    coordinator.handleButtonTap(
      codex: service, onTranscript: { _ in XCTFail() }, onDismissInput: {})
    coordinator.handleScenePhaseChange(
      .background, codex: service, onTranscript: { _ in XCTFail() }, onDismissInput: {})
    await settleTasks()
    XCTAssertEqual(capture.startCount, 0)
    XCTAssertFalse(coordinator.isInputActive)
  }

  func testExplicitCancelAndViewDisappearInvalidateAlreadyQueuedStart() async {
    for disappear in [false, true] {
      let service = makeService()
      let capture = CaptureFixture()
      let coordinator = makeCoordinator(capture)
      service.requestTransportOverride = { _, _ in
        XCTFail("An abandoned queued start must not warm or upload voice")
        return self.response(text: "unused")
      }
      coordinator.handleButtonTap(
        codex: service, onTranscript: { _ in XCTFail() }, onDismissInput: {})
      if disappear {
        coordinator.handleViewDisappear(
          scenePhase: .active, codex: service, onTranscript: { _ in XCTFail() },
          onDismissInput: {})
      } else {
        coordinator.cancelInputIfNeeded()
      }
      await settleTasks()
      XCTAssertEqual(capture.startCount, 0)
      XCTAssertEqual(capture.cancelCount, 0)
      XCTAssertFalse(coordinator.isInputActive)
    }
  }

  func testCancellationDuringInputDismissalNeverStartsCapture() async {
    let service = makeService()
    let capture = CaptureFixture()
    let coordinator = makeCoordinator(capture)
    coordinator.handleButtonTap(
      codex: service, onTranscript: { _ in XCTFail() },
      onDismissInput: { coordinator.cancelInputIfNeeded() })
    await settleTasks()
    XCTAssertEqual(capture.startCount, 0)
    XCTAssertFalse(coordinator.isInputActive)
  }

  func testLateSuccessAndErrorFromOldStartDoNotCancelOrResetReplacementCapture() async {
    for oldStartThrows in [false, true] {
      let service = makeService()
      let capture = CaptureFixture()
      capture.suspendsStart = true
      let coordinator = makeCoordinator(capture)
      service.requestTransportOverride = { _, _ in self.response(text: "unused") }
      coordinator.handleButtonTap(
        codex: service, onTranscript: { _ in XCTFail() }, onDismissInput: {})
      await waitUntil { capture.startContinuation != nil }
      let first = capture.startContinuation
      capture.startContinuation = nil
      coordinator.cancelInputIfNeeded()
      coordinator.handleButtonTap(
        codex: service, onTranscript: { _ in XCTFail() }, onDismissInput: {})
      await waitUntil { capture.startCount == 2 && capture.startContinuation != nil }
      capture.startContinuation?.resume()
      capture.startContinuation = nil
      await waitUntil { coordinator.isRecording }
      let cancelsBeforeLateResult = capture.cancelCount
      let resetsBeforeLateResult = capture.resetCount
      if oldStartThrows {
        first?.resume(throwing: GPTVoiceTranscriptionError.unableToConfigureAudioSession)
      } else {
        first?.resume()
      }
      await settleTasks()
      XCTAssertTrue(coordinator.isRecording)
      XCTAssertFalse(coordinator.isPreflighting)
      XCTAssertEqual(capture.cancelCount, cancelsBeforeLateResult)
      XCTAssertEqual(capture.resetCount, resetsBeforeLateResult)
      XCTAssertNil(coordinator.recoveryReason)
      XCTAssertEqual(capture.stopCount, 0)
      coordinator.cancelInputIfNeeded()
    }
  }

  func testSampleCollectorBoundsAppendBeforeStopAndRejectsOldSessionSamples() {
    let collector = AudioSampleCollector()
    collector.beginSession(1, sampleRate: 48_000)
    for _ in 0..<29 {
      XCTAssertEqual(
        collector.appendSamples([Float](repeating: 0, count: 48_000), sessionID: 1)?.count, 48_000)
    }
    XCTAssertEqual(
      collector.appendSamples([Float](repeating: 0, count: 96_000), sessionID: 1)?.count, 48_000)
    XCTAssertNil(collector.appendSamples([1], sessionID: 1))
    XCTAssertEqual(collector.drain(sessionID: 1).count, 1_440_000)
    collector.beginSession(2, sampleRate: 24_000)
    XCTAssertNil(collector.appendSamples([1], sessionID: 1))
    XCTAssertTrue(collector.drain(sessionID: 1).isEmpty)
    XCTAssertEqual(collector.appendSamples([2, 3], sessionID: 2), [2, 3])
    XCTAssertEqual(collector.drain(sessionID: 2), [2, 3])
  }

  func testRecordingClockUsesRealElapsedTimeAfterDelayedTicksAndClampsAtLimit() {
    XCTAssertEqual(VoiceCaptureTiming.elapsed(startedAt: 100, now: 125.5), 25.5)
    XCTAssertEqual(VoiceCaptureTiming.elapsed(startedAt: 100, now: 200), 30)
    XCTAssertEqual(VoiceCaptureTiming.elapsed(startedAt: 100, now: 99), 0)
  }

  func testBackgroundCancelsPendingPermissionAndIgnoresLateStartSuccess() async {
    let service = makeService()
    let capture = CaptureFixture()
    capture.suspendsStart = true
    let coordinator = makeCoordinator(capture)
    service.requestTransportOverride = { _, _ in self.response(text: "unused") }
    coordinator.handleButtonTap(
      codex: service, onTranscript: { _ in XCTFail() }, onDismissInput: {})
    await waitUntil { capture.startContinuation != nil }

    coordinator.handleScenePhaseChange(
      .background, codex: service, onTranscript: { _ in XCTFail() }, onDismissInput: {})
    XCTAssertFalse(coordinator.isPreflighting)
    capture.startContinuation?.resume()
    capture.startContinuation = nil
    await settleTasks()

    XCTAssertFalse(coordinator.isInputActive)
    XCTAssertGreaterThanOrEqual(capture.cancelCount, 1)
    XCTAssertEqual(capture.stopCount, 0)
  }

  func testInactiveCancelsExplicitStopBeforeItsQueuedTaskCanPrepareAudio() async {
    let service = makeService()
    let capture = CaptureFixture()
    let coordinator = makeCoordinator(capture)
    var methods: [String] = []
    service.requestTransportOverride = { method, _ in
      methods.append(method)
      return self.response(text: "unused")
    }
    coordinator.handleButtonTap(
      codex: service, onTranscript: { _ in XCTFail() }, onDismissInput: {})
    await waitUntil { coordinator.isRecording }
    coordinator.handleButtonTap(
      codex: service, onTranscript: { _ in XCTFail() }, onDismissInput: {})
    XCTAssertTrue(coordinator.isTranscribing)
    coordinator.handleScenePhaseChange(
      .inactive, codex: service, onTranscript: { _ in XCTFail() }, onDismissInput: {})
    await settleTasks()
    XCTAssertFalse(coordinator.isInputActive)
    XCTAssertEqual(capture.stopCount, 0)
    XCTAssertFalse(methods.contains("voice/transcribe"))
  }

  func testBackgroundSuppressesLateTranscriptAndRemovesTemporaryClip() async throws {
    let service = makeService()
    let capture = CaptureFixture()
    let clip = try makeClip(duration: 1)
    defer { try? FileManager.default.removeItem(at: clip.url) }
    capture.clip = clip
    let coordinator = makeCoordinator(capture)
    var pendingResponse: CheckedContinuation<RPCMessage, Never>?
    var transcripts: [String] = []
    service.requestTransportOverride = { method, _ in
      if method == "voice/transcribe" {
        return await withCheckedContinuation { pendingResponse = $0 }
      }
      XCTAssertEqual(method, "voice/prewarm")
      return self.response(text: "unused")
    }
    coordinator.handleButtonTap(
      codex: service, onTranscript: { transcripts.append($0) }, onDismissInput: {})
    await waitUntil { coordinator.isRecording }
    coordinator.handleButtonTap(
      codex: service, onTranscript: { transcripts.append($0) }, onDismissInput: {})
    await waitUntil { pendingResponse != nil }

    coordinator.handleScenePhaseChange(
      .background, codex: service, onTranscript: { transcripts.append($0) }, onDismissInput: {})
    pendingResponse?.resume(returning: response(text: "late result"))
    pendingResponse = nil
    await waitUntil { !FileManager.default.fileExists(atPath: clip.url.path) }

    XCTAssertFalse(coordinator.isInputActive)
    XCTAssertTrue(transcripts.isEmpty)
    XCTAssertNil(coordinator.recoveryReason)
  }

  func testCancelledTranscriptionDoesNotStartAccountRecoveryRequests() async throws {
    let service = makeService()
    let clip = try makeClip(duration: 1)
    defer { try? FileManager.default.removeItem(at: clip.url) }
    var methods: [String] = []
    service.requestTransportOverride = { method, _ in
      methods.append(method)
      throw CancellationError()
    }
    do {
      _ = try await service.transcribeVoiceAudioFile(at: clip.url, durationSeconds: 1)
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    await settleTasks()
    XCTAssertEqual(methods, ["voice/transcribe"])
  }

  private func makeService() -> CodexService {
    let suiteName = "MunieVoiceInputTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let service = CodexService(defaults: defaults)
    Self.retainedServices.append(service)
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    service.isConnected = true
    return service
  }

  private func makeCoordinator(_ fixture: CaptureFixture) -> VoiceInputCoordinator {
    VoiceInputCoordinator(
      capture: VoiceCaptureOperations(
        start: {
          fixture.startCount += 1
          if fixture.suspendsStart {
            try await withCheckedThrowingContinuation { fixture.startContinuation = $0 }
          }
        },
        stop: { _ in
          fixture.stopCount += 1
          return fixture.clip
        },
        cancel: { fixture.cancelCount += 1 }, resetMetering: { fixture.resetCount += 1 }))
  }

  private func response(text: String) -> RPCMessage {
    RPCMessage(
      id: .string(UUID().uuidString), result: .object(["text": .string(text)]),
      includeJSONRPC: false)
  }

  private func waitUntil(
    file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
  ) async {
    for _ in 0..<1_000 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Expected asynchronous fixture transition", file: file, line: line)
  }

  private func settleTasks() async {
    for _ in 0..<10 { await Task.yield() }
  }

  private func makeClip(duration: TimeInterval) throws -> GPTVoiceRecordingClip {
    // Synthetic 24 kHz mono PCM WAV: no microphone, model or network input.
    var data = Data("RIFF".utf8)
    data.append(contentsOf: [38, 0, 0, 0])
    data.append(contentsOf: "WAVEfmt ".utf8)
    data.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 192, 93, 0, 0])
    data.append(contentsOf: [128, 187, 0, 0, 2, 0, 16, 0])
    data.append(contentsOf: "data".utf8)
    data.append(contentsOf: [2, 0, 0, 0, 0, 0])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    try data.write(to: url)
    return GPTVoiceRecordingClip(
      url: url, mimeType: "audio/wav", durationSeconds: duration, byteCount: data.count)
  }
}

@MainActor
private final class CaptureFixture {
  var startCount = 0
  var stopCount = 0
  var cancelCount = 0
  var resetCount = 0
  var suspendsStart = false
  var startContinuation: CheckedContinuation<Void, Error>?
  var clip: GPTVoiceRecordingClip?
}
