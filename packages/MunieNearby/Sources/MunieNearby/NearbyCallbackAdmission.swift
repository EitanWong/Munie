import Foundation
import os

/// Bounds Objective-C discovery callbacks before creating MainActor tasks.
/// A source identity and generation keep callbacks from a stopped browser or
/// advertiser from consuming the next owner's budget.
final class NearbyCallbackAdmission: Sendable {
  private struct State {
    var source: ObjectIdentifier?
    var generation = UUID()
    var pending = 0
    var recent: [Date] = []
  }
  private let storage = OSAllocatedUnfairLock(initialState: State())
  private let maximumPending: Int
  private let maximumPerMinute: Int?

  init(maximumPending: Int = 16, maximumPerMinute: Int? = nil) {
    self.maximumPending = maximumPending
    self.maximumPerMinute = maximumPerMinute
  }

  func activate(_ source: AnyObject) {
    let identity = ObjectIdentifier(source)
    storage.withLock {
      $0.source = identity
      $0.generation = UUID()
      $0.pending = 0
    }
  }

  func invalidate() {
    storage.withLock {
      $0.source = nil
      $0.generation = UUID()
      $0.pending = 0
    }
  }

  func admit(_ source: AnyObject, now: Date = Date()) -> UUID? {
    let identity = ObjectIdentifier(source)
    return storage.withLock {
      guard $0.source == identity, $0.pending < maximumPending else { return nil }
      if let maximumPerMinute {
        $0.recent.removeAll { now.timeIntervalSince($0) >= 60 }
        guard $0.recent.count < maximumPerMinute else { return nil }
        $0.recent.append(now)
      }
      $0.pending += 1
      return $0.generation
    }
  }

  func release(_ token: UUID) {
    storage.withLock {
      guard $0.generation == token, $0.pending > 0 else { return }
      $0.pending -= 1
    }
  }
}
