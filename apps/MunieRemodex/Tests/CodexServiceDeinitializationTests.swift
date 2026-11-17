import Foundation
import XCTest

@testable import MunieRemodex

private actor CodexServiceBackgroundOwner {
  private var service: CodexService?

  init(_ service: CodexService) {
    self.service = service
  }

  func releaseService() {
    service = nil
  }
}

@MainActor
final class CodexServiceDeinitializationTests: XCTestCase {
  func testLastReleaseOutsideMainActorCancelsOwnedWorkWithoutTrapping() async throws {
    let suiteName = "CodexServiceDeinitializationTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var service: CodexService? = CodexService(defaults: defaults)
    // This regression exercises ownership and executor hopping without a live network callback.
    service?.networkPathMonitor?.cancel()
    service?.networkPathMonitor = nil

    let started = expectation(description: "Owned task starts")
    let cancelled = expectation(description: "Isolated deinit cancels owned task")
    let ownedTask = Task { @MainActor in
      started.fulfill()
      do {
        try await Task.sleep(nanoseconds: 60_000_000_000)
      } catch is CancellationError {
        cancelled.fulfill()
      } catch {
        XCTFail("Unexpected owned task error: \(error)")
      }
    }
    service?.messagePersistenceDebounceTask = ownedTask
    await fulfillment(of: [started], timeout: 2)

    weak var releasedService = service
    let owner = CodexServiceBackgroundOwner(try XCTUnwrap(service))
    service = nil
    await owner.releaseService()

    await fulfillment(of: [cancelled], timeout: 2)
    ownedTask.cancel()
    await ownedTask.value
    XCTAssertNil(releasedService)
  }
}
