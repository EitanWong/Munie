import Foundation
import XCTest

@testable import MunieRemodex

@MainActor
final class NearbyConnectionAttemptTests: XCTestCase {
  // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
  nonisolated deinit {}

  func testExistingPairingErrorIsLocalizedWithoutChangingTrustState() throws {
    let suite = "NearbyConnectionAttemptTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let service = CodexService(defaults: defaults)
    let previous = service.secureConnectionState
    let rawText = #"{"kind":"secureError","code":"phone_already_trusted","message":"Untrusted remote copy."}"#
    let expected = String(
      localized: "This Mac is paired with another iPhone. Remove that pairing on the Mac to continue.")

    service.processIncomingWireText(rawText)
    XCTAssertEqual(service.lastErrorMessage, expected)
    XCTAssertEqual(service.secureConnectionState, previous)
  }

  func testSuccessCommitsBeforeRemovingOnboardingAndDoesNotDisconnect() async {
    let connected = expectation(description: "Connected")
    let attempt = NearbyConnectionAttempt()
    var disconnects = 0
    var completions = 0
    attempt.start(
      expiresAt: Date().addingTimeInterval(60), connect: { true },
      disconnect: { disconnects += 1 },
      onConnected: {
        XCTAssertEqual(attempt.phase, .completed)
        attempt.cancel()  // View removal must not cancel a committed connection.
        completions += 1
        connected.fulfill()
      })
    await fulfillment(of: [connected], timeout: 2)
    XCTAssertEqual(attempt.phase, .completed)
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(disconnects, 0)
  }

  func testFailureStaysRecoverableAndRetryCanConnect() async {
    let disconnected = expectation(description: "Failure cleanup")
    let connected = expectation(description: "Retry connected")
    let attempt = NearbyConnectionAttempt()
    attempt.start(
      expiresAt: Date().addingTimeInterval(60), connect: { false },
      disconnect: { disconnected.fulfill() },
      onConnected: { XCTFail("Failure must not finish onboarding") })
    await fulfillment(of: [disconnected], timeout: 2)
    XCTAssertEqual(attempt.phase, .failed)
    attempt.resetFailure()
    XCTAssertEqual(attempt.phase, .idle)
    attempt.start(
      expiresAt: Date().addingTimeInterval(60), connect: { true }, disconnect: {},
      onConnected: { connected.fulfill() })
    await fulfillment(of: [connected], timeout: 2)
    XCTAssertEqual(attempt.phase, .completed)
  }

  func testCancellingQueuedHandoffSkipsAllConnectionCallbacks() async {
    let unexpectedCallback = expectation(description: "No callbacks for a cancelled queued handoff")
    unexpectedCallback.isInverted = true
    unexpectedCallback.assertForOverFulfill = false
    let attempt = NearbyConnectionAttempt()
    attempt.start(
      expiresAt: Date().addingTimeInterval(60),
      connect: {
        unexpectedCallback.fulfill()
        return true
      },
      disconnect: { unexpectedCallback.fulfill() },
      onConnected: { unexpectedCallback.fulfill() })

    // Both calls are in the same main-actor turn, before the connection task can start.
    attempt.cancel()
    XCTAssertEqual(attempt.phase, .idle)
    await fulfillment(of: [unexpectedCallback], timeout: 0.1)
    XCTAssertEqual(attempt.phase, .idle)
  }

  func testCancelOrBackgroundRejectsLateSuccessAndBlocksRetryUntilCleanup() async {
    let started = expectation(description: "Connection started")
    let stopped = expectation(description: "Both disconnects finished")
    let attempt = NearbyConnectionAttempt()
    var continuation: CheckedContinuation<Bool, Never>?
    var disconnects = 0
    attempt.start(
      expiresAt: Date().addingTimeInterval(60),
      connect: {
        await withCheckedContinuation {
          continuation = $0
          started.fulfill()
        }
      },
      disconnect: {
        disconnects += 1
        if disconnects == 2 { stopped.fulfill() }
      }, onConnected: { XCTFail("Cancelled handoff must not finish onboarding") })
    await fulfillment(of: [started], timeout: 2)
    attempt.cancel()  // Both the Cancel button and background lifecycle use this path.
    XCTAssertEqual(attempt.phase, .cancelling)
    attempt.start(
      expiresAt: Date().addingTimeInterval(60),
      connect: {
        XCTFail("Must wait for teardown")
        return true
      }, disconnect: {},
      onConnected: { XCTFail("Must wait for teardown") })
    continuation?.resume(returning: true)
    await fulfillment(of: [stopped], timeout: 2)
    XCTAssertEqual(attempt.phase, .idle)
    XCTAssertEqual(disconnects, 2)
  }

  func testPayloadExpiringDuringHandoffCannotFinishOnboarding() async {
    let started = expectation(description: "Connection started")
    let stopped = expectation(description: "Expired connection removed")
    var now = Date()
    let expiresAt = now.addingTimeInterval(60)
    let attempt = NearbyConnectionAttempt(now: { now })
    var continuation: CheckedContinuation<Bool, Never>?
    attempt.start(
      expiresAt: expiresAt,
      connect: {
        await withCheckedContinuation {
          continuation = $0
          started.fulfill()
        }
      }, disconnect: { stopped.fulfill() },
      onConnected: { XCTFail("Expired payload must not finish onboarding") })
    await fulfillment(of: [started], timeout: 2)
    now = expiresAt
    continuation?.resume(returning: true)
    await fulfillment(of: [stopped], timeout: 2)
    XCTAssertEqual(attempt.phase, .failed)
  }

  func testExpiredPayloadDoesNotStartAnyConnection() {
    let now = Date()
    let attempt = NearbyConnectionAttempt(now: { now })
    attempt.start(
      expiresAt: now,
      connect: {
        XCTFail("Expired payload")
        return true
      },
      disconnect: { XCTFail("Nothing connected") },
      onConnected: { XCTFail("Expired payload") })
    XCTAssertEqual(attempt.phase, .failed)
  }
}
