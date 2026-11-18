import Foundation
import Network
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
  // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
  nonisolated deinit {}

  func testLastReleaseOutsideMainActorCancelsAllOwnedWorkWithoutTrapping() async throws {
    let suiteName = "CodexServiceDeinitializationTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var service: CodexService? = CodexService(defaults: defaults)
    // Keep this regression independent of live network callbacks, but retain an
    // unstarted monitor to verify final release does not leak the owned resource.
    service?.networkPathMonitor?.cancel()
    service?.networkPathMonitor = NWPathMonitor()
    weak var releasedMonitor = service?.networkPathMonitor

    let taskProperties: [ReferenceWritableKeyPath<CodexService, Task<Void, Never>?>] = [
      \.messagePersistenceDebounceTask,
      \.compactRuntimeItemCompletedFlushTask,
      \.coalescedRevertRefreshTask,
      \.pendingImmediateSyncTask,
      \.threadListSyncTask,
      \.activeThreadSyncTask,
      \.runningThreadWatchSyncTask,
      \.postConnectSyncTask,
      \.gptAccountLoginSyncTask,
    ]
    let started = expectation(description: "All ten owned tasks start")
    started.expectedFulfillmentCount = taskProperties.count + 1
    let cancelled = expectation(description: "Final release cancels all ten owned tasks")
    cancelled.expectedFulfillmentCount = taskProperties.count + 1
    var ownedTasks: [Task<Void, Never>] = []
    for property in taskProperties {
      let task = Task { @MainActor in
        started.fulfill()
        do {
          try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
          cancelled.fulfill()
        } catch {
          XCTFail("Unexpected owned task error: \(error)")
        }
      }
      service?[keyPath: property] = task
      ownedTasks.append(task)
    }
    let resolveTask = Task<CodexTrustedSessionResolveResponse, Error> { @MainActor in
      started.fulfill()
      do {
        try await Task.sleep(nanoseconds: 60_000_000_000)
      } catch is CancellationError {
        cancelled.fulfill()
        throw CancellationError()
      }
      throw URLError(.timedOut)
    }
    service?.trustedSessionResolveTask = resolveTask
    // Always drain fixture tasks, including when an assertion exposes a regression.
    defer {
      for task in ownedTasks { task.cancel() }
      resolveTask.cancel()
    }
    await fulfillment(of: [started], timeout: 2)

    weak var releasedService = service
    weak var releasedReviewCoordinator = service?.appReviewPromptCoordinator
    let owner = CodexServiceBackgroundOwner(try XCTUnwrap(service))
    service = nil
    await owner.releaseService()

    // All cancellation is synchronous with the off-main final release.
    XCTAssertTrue(ownedTasks.allSatisfy(\.isCancelled))
    XCTAssertTrue(resolveTask.isCancelled)
    XCTAssertNil(releasedService)
    XCTAssertNil(releasedMonitor)
    XCTAssertNil(releasedReviewCoordinator)
    await fulfillment(of: [cancelled], timeout: 2)
    for task in ownedTasks { task.cancel() }
    resolveTask.cancel()
    for task in ownedTasks { await task.value }
    _ = await resolveTask.result
  }

  func testLastReleaseOutsideMainActorRemovesNotificationObserversSynchronously() async throws {
    let suiteName = "CodexServiceDeinitializationTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var service: CodexService? = CodexService(defaults: defaults)
    service?.networkPathMonitor?.cancel()
    service?.networkPathMonitor = nil

    let name = Notification.Name("CodexServiceDeinitializationTests." + UUID().uuidString)
    let received = expectation(description: "Observer receives only the pre-release notification")
    received.assertForOverFulfill = true
    let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
      _ in
      received.fulfill()
    }
    // Retain the token in the test too: unregistering must be an explicit lifetime
    // action, independent of whether Foundation deallocates its observer token.
    defer { NotificationCenter.default.removeObserver(token) }
    service?.notificationObserverTokens = [token]
    NotificationCenter.default.post(name: name, object: nil)
    await fulfillment(of: [received], timeout: 2)

    weak var releasedService = service
    let owner = CodexServiceBackgroundOwner(try XCTUnwrap(service))
    service = nil
    await owner.releaseService()
    XCTAssertNil(releasedService)
    // queue:nil delivery is synchronous; a retained registration overfulfills.
    NotificationCenter.default.post(name: name, object: nil)
  }
}
