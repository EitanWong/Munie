import Foundation
import XCTest

@testable import MunieRemodex

@MainActor
final class NearbyPairingRouteTests: XCTestCase {
  private func visible(
    _ route: NearbyPairingRoute, connected: Bool = false,
    paired: Bool = false, recovering: Bool = false, dismissed: Bool = false
  ) -> Bool {
    route.shouldPresent(
      isConnected: connected, hasReconnectCandidate: paired,
      isManualPairing: false, isRecovering: recovering,
      hasDismissedAutomaticPairing: dismissed)
  }

  func testPostOnboardingWithoutPairingOffersNearbyAndSavedPairingKeepsReconnect() {
    let route = NearbyPairingRoute()
    XCTAssertTrue(visible(route))
    XCTAssertFalse(visible(route, paired: true))
    XCTAssertFalse(visible(route, connected: true))
    XCTAssertFalse(visible(route, recovering: true))
    XCTAssertFalse(visible(route, dismissed: true))
  }

  func testForgetPairReopensNearbyAfterPreviousCompletedAndDismissedRoute() {
    var route = NearbyPairingRoute()
    route.present()
    let first = route.id
    XCTAssertTrue(route.hold(first, targetMacDeviceID: "old-mac"))
    XCTAssertTrue(route.finish(first))
    XCTAssertFalse(visible(route, paired: true, dismissed: true))
    // Forget Pair explicitly presents the route, even if the automatic screen was dismissed.
    route.present()
    XCTAssertNotEqual(route.id, first)
    XCTAssertTrue(visible(route, dismissed: true))
    XCTAssertNil(route.targetMacDeviceID)
  }

  func testNewMacRouteSurvivesLiveOldMacAndRecoveryState() {
    var route = NearbyPairingRoute()
    route.present()
    XCTAssertTrue(visible(route, connected: true, paired: true, recovering: true, dismissed: true))
    let requestID = route.id
    route.present()
    XCTAssertEqual(route.id, requestID, "Repeated presentation must not replace an active owner")
  }

  func testRememberedBootstrapAndEarlyConnectedDoNotRemoveAnUncommittedHandoff() {
    var route = NearbyPairingRoute()
    let requestID = route.id
    XCTAssertTrue(route.hold(requestID, targetMacDeviceID: "new-mac"))
    XCTAssertTrue(visible(route, paired: true, recovering: true))
    XCTAssertTrue(visible(route, connected: true, paired: true))
    XCTAssertEqual(route.targetMacDeviceID, "new-mac")
    XCTAssertTrue(route.finish(requestID))
    XCTAssertFalse(visible(route, connected: true, paired: true))
  }

  func testStaleScreenCannotHoldOrFinishTheNextPairingGeneration() {
    var route = NearbyPairingRoute()
    route.present()
    let stale = route.id
    XCTAssertTrue(route.finish(stale))
    route.present()
    XCTAssertFalse(route.hold(stale, targetMacDeviceID: "stale-mac"))
    XCTAssertFalse(route.finish(stale))
    XCTAssertTrue(route.isPresented)
    XCTAssertNil(route.targetMacDeviceID)
  }

  func testFailurePreservationBelongsOnlyToTheMatchingAttempt() {
    var route = NearbyPairingRoute()
    route.present()
    let requestID = route.id
    XCTAssertTrue(route.hold(requestID, targetMacDeviceID: "same-or-new-mac"))
    route.preserveExistingConnectionAfterFailure(requestID)
    XCTAssertTrue(route.preservesExistingConnectionOnFailure)
    XCTAssertTrue(route.hold(requestID, targetMacDeviceID: "retry"))
    XCTAssertFalse(route.preservesExistingConnectionOnFailure)
    XCTAssertTrue(route.finish(requestID))
    route.present()
    route.preserveExistingConnectionAfterFailure(requestID)
    XCTAssertFalse(route.preservesExistingConnectionOnFailure)
  }

  func testReadyOldMacOrWrongSessionCannotCompleteTheNewPairing() {
    var route = NearbyPairingRoute()
    let requestID = route.id
    XCTAssertTrue(
      route.hold(requestID, targetMacDeviceID: "new-mac", targetSessionID: "new-session"))
    XCTAssertFalse(
      route.matchesConnectedTarget(
        requestID, currentMacDeviceID: "old-mac", relaySessionID: "old-session",
        isConnected: true, isInitialized: true))
    XCTAssertFalse(
      route.matchesConnectedTarget(
        requestID, currentMacDeviceID: "new-mac", relaySessionID: "old-session",
        isConnected: true, isInitialized: true))
    XCTAssertFalse(
      route.matchesConnectedTarget(
        requestID, currentMacDeviceID: "new-mac", relaySessionID: "new-session",
        isConnected: true, isInitialized: false))
    XCTAssertFalse(
      route.matchesConnectedTarget(
        UUID(), currentMacDeviceID: "new-mac", relaySessionID: "new-session",
        isConnected: true, isInitialized: true))
    XCTAssertTrue(route.isPresented)
    XCTAssertTrue(
      route.matchesConnectedTarget(
        requestID, currentMacDeviceID: "new-mac", relaySessionID: "new-session",
        isConnected: true, isInitialized: true))
  }

  func testActualAttemptCommitsBeforeClosingEarlyConnectedRoute() async {
    let started = expectation(description: "Socket connected before initialization")
    let completed = expectation(description: "Handoff committed")
    let attempt = NearbyConnectionAttempt()
    var route = NearbyPairingRoute()
    let requestID = route.id
    var socketConnected = false
    var initialized = false
    var initialization: CheckedContinuation<Bool, Never>?
    attempt.start(
      expiresAt: Date().addingTimeInterval(60),
      connect: {
        XCTAssertTrue(route.hold(requestID, targetMacDeviceID: "new-mac"))
        socketConnected = true
        let ready = await withCheckedContinuation {
          initialization = $0
          started.fulfill()
        }
        initialized = ready
        return ready
      },
      disconnect: { XCTFail("Committed handoff should survive view removal") },
      onConnected: {
        XCTAssertEqual(attempt.phase, .completed)
        XCTAssertTrue(route.finish(requestID))
        attempt.cancel()  // Nearby view disappears only after the commit above.
        completed.fulfill()
      })
    await fulfillment(of: [started], timeout: 2)
    XCTAssertEqual(attempt.phase, .connecting)
    XCTAssertFalse(initialized)
    XCTAssertTrue(visible(route, connected: socketConnected, paired: true))
    initialization?.resume(returning: true)
    await fulfillment(of: [completed], timeout: 2)
    XCTAssertTrue(initialized)
    XCTAssertFalse(visible(route, connected: socketConnected, paired: true))
  }

  func testFailedSwitchKeepsOldMacAliveAndNearbyRouteAvailable() async {
    let failed = expectation(description: "Failed switch cleanup")
    let attempt = NearbyConnectionAttempt()
    var route = NearbyPairingRoute()
    let requestID = route.id
    var oldMacConnected = true
    attempt.start(
      expiresAt: Date().addingTimeInterval(60),
      connect: {
        XCTAssertTrue(route.hold(requestID, targetMacDeviceID: "new-mac"))
        route.preserveExistingConnectionAfterFailure(requestID)
        return false
      },
      disconnect: {
        if !route.preservesExistingConnectionOnFailure { oldMacConnected = false }
        failed.fulfill()
      }, onConnected: { XCTFail("Failed switch must keep the retry route") })
    await fulfillment(of: [failed], timeout: 2)
    XCTAssertEqual(attempt.phase, .failed)
    XCTAssertTrue(oldMacConnected)
    XCTAssertTrue(visible(route, connected: oldMacConnected, paired: true))
    XCTAssertTrue(route.isPresented)
  }

  func testEarlyConnectedCancellationRejectsLateSuccessAndLeavesNearbyRetry() async {
    let started = expectation(description: "Early socket")
    let stopped = expectation(description: "Cleanup finished")
    let attempt = NearbyConnectionAttempt()
    var route = NearbyPairingRoute()
    let requestID = route.id
    var continuation: CheckedContinuation<Bool, Never>?
    var disconnects = 0
    attempt.start(
      expiresAt: Date().addingTimeInterval(60),
      connect: {
        XCTAssertTrue(route.hold(requestID, targetMacDeviceID: "new-mac"))
        return await withCheckedContinuation {
          continuation = $0
          started.fulfill()
        }
      },
      disconnect: {
        disconnects += 1
        if disconnects == 2 { stopped.fulfill() }
      }, onConnected: { XCTFail("Late cancelled success must not close the route") })
    await fulfillment(of: [started], timeout: 2)
    XCTAssertTrue(visible(route, connected: true, paired: true))
    attempt.cancel()
    continuation?.resume(returning: true)
    await fulfillment(of: [stopped], timeout: 2)
    XCTAssertEqual(attempt.phase, .idle)
    XCTAssertTrue(visible(route, paired: true, recovering: true, dismissed: true))
    XCTAssertTrue(route.isPresented)
  }
}
