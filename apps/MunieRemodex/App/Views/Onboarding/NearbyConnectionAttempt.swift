// Munie modification: explicit nonisolated teardown for Swift 6.2 runtime compatibility.
import Combine
import Foundation

/// Owns the relay handoff after nearby confirmation. Completion is committed
/// before the onboarding view is removed; interrupted attempts finish teardown
/// before another connection can begin.
@MainActor
final class NearbyConnectionAttempt: ObservableObject {
  // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
  nonisolated deinit {}

  enum Phase { case idle, connecting, cancelling, failed, completed }

  @Published private(set) var phase: Phase = .idle
  private var operation: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  private var generation = UUID()
  private let now: () -> Date
  private var disconnect: (() async -> Void)?

  init(now: @escaping () -> Date = Date.init) { self.now = now }

  func start(
    expiresAt: Date,
    connect: @escaping () async -> Bool,
    disconnect: @escaping () async -> Void,
    onConnected: @escaping () -> Void
  ) {
    guard phase == .idle || phase == .failed else { return }
    guard expiresAt > now() else {
      phase = .failed
      return
    }
    generation = UUID()
    let token = generation
    self.disconnect = disconnect
    phase = .connecting
    operation = Task { [weak self] in
      let connected = await connect()
      guard let self, self.generation == token, self.phase == .connecting else { return }
      if connected, !Task.isCancelled, expiresAt > self.now() {
        self.deadline?.cancel()
        self.deadline = nil
        self.operation = nil
        self.disconnect = nil
        self.phase = .completed
        onConnected()
      } else {
        await disconnect()
        guard self.generation == token, self.phase == .connecting else { return }
        self.deadline?.cancel()
        self.deadline = nil
        self.operation = nil
        self.disconnect = nil
        self.phase = .failed
      }
    }
    let remaining = min(120, expiresAt.timeIntervalSince(now()))
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, remaining))) } catch { return }
      guard let self, self.generation == token else { return }
      self.cancel(finishingAt: .failed)
    }
  }

  func cancel() { cancel(finishingAt: .idle) }

  func resetFailure() {
    guard phase == .failed else { return }
    phase = .idle
  }

  private func cancel(finishingAt finalPhase: Phase) {
    guard phase == .connecting, let disconnect else { return }
    generation = UUID()
    let token = generation
    phase = .cancelling
    deadline?.cancel()
    deadline = nil
    let interrupted = operation
    interrupted?.cancel()
    operation = Task { [weak self] in
      // Disconnect immediately to release pending socket work, then repeat after
      // it returns so a late successful handshake cannot survive cancellation.
      await disconnect()
      await interrupted?.value
      await disconnect()
      guard let self, self.generation == token else { return }
      self.operation = nil
      self.disconnect = nil
      self.phase = finalPhase
    }
  }
}
