import XCTest

@testable import MunieDeviceIdentityProbe

@MainActor
final class SessionInvalidationTests: XCTestCase {
  func testInvalidationBeforeWaitingIsRemembered() async {
    let lifecycle = SessionInvalidation()
    lifecycle.observe()
    let completed = expectation(description: "Earlier final callback remains observable")
    let waiter = Task {
      await lifecycle.wait {}
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 2)
    waiter.cancel()
  }

  func testFinalCallbackDuringInvalidationResumesExactlyOnce() async {
    let lifecycle = SessionInvalidation()
    let completed = expectation(description: "Callback releases registered cleanup owner")
    completed.assertForOverFulfill = true
    let waiter = Task {
      await lifecycle.wait {
        lifecycle.observe()
        lifecycle.observe()
      }
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 2)
    waiter.cancel()
  }
}
