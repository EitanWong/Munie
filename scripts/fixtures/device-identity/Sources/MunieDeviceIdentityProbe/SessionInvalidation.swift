import Synchronization

/// A session may invalidate itself before the owner starts waiting for cleanup.
/// Keep that observation so an early final delegate callback cannot be lost.
final class SessionInvalidation: Sendable {
  private struct State {
    var observed = false
    var waiter: CheckedContinuation<Void, Never>?
  }
  private let state = Mutex(State())

  func observe() {
    let waiter = state.withLock {
      $0.observed = true
      let waiter = $0.waiter
      $0.waiter = nil
      return waiter
    }
    waiter?.resume()
  }

  func wait(invalidate: @Sendable () -> Void) async {
    await withCheckedContinuation { continuation in
      let observed = state.withLock {
        if $0.observed { return true }
        precondition($0.waiter == nil, "The session has one cleanup owner")
        $0.waiter = continuation
        return false
      }
      if observed { continuation.resume() }
      invalidate()
    }
  }
}
