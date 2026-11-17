import Darwin
import Foundation

@testable import MunieExecutionHost

enum HostFixtureOwnerReleaseError: Error { case ownerNotReleased }

/// Test-only observation of ARC completion and this fixture's real single-owner lock.
struct HostFixtureOwnerRelease: Sendable {
  weak var ledger: HostSubmissionLedger?
  let store: URL

  func wait() async throws {
    // Async call frames can retain actors beyond helper return; weak references can clear before
    // deinit finishes. Observe both without retrying the production storage initializer.
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while ledger != nil {
      guard clock.now < deadline else { throw HostFixtureOwnerReleaseError.ownerNotReleased }
      try await clock.sleep(for: .milliseconds(2))
    }
    let descriptor = open(
      store.appendingPathComponent(".owner").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw HostFixtureOwnerReleaseError.ownerNotReleased }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EAGAIN, clock.now < deadline else {
        throw HostFixtureOwnerReleaseError.ownerNotReleased
      }
      try await clock.sleep(for: .milliseconds(2))
    }
    guard flock(descriptor, LOCK_UN) == 0 else {
      throw HostFixtureOwnerReleaseError.ownerNotReleased
    }
  }
}
