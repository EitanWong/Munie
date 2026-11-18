import Foundation
@preconcurrency import MultipeerConnectivity
import XCTest

@testable import MunieNearby

@MainActor
final class NearbyMailboxTests: XCTestCase {
  func testEventFloodCollapsesToOneFailureAndRejectsFurtherCallbacks() async {
    var events: [NearbySessionDelegate.Event] = []
    let delegate = NearbySessionDelegate(
      generation: UUID(), expectedPeer: MCPeerID(displayName: "Mac")
    ) {
      _, event in events.append(event)
    }
    for _ in 0..<100 { delegate.enqueue(.data(value: Data([1]))) }
    await Task.yield()
    XCTAssertEqual(events.count, 1)
    if case .unsupportedTransfer = events.first {
    } else {
      XCTFail("Expected one terminal overflow")
    }
    delegate.enqueue(.data(value: Data([2])))
    await Task.yield()
    XCTAssertEqual(events.count, 1)
  }

  func testByteLimitFailsBeforeEventCountLimit() async {
    var count = 0
    var failures = 0
    let delegate = NearbySessionDelegate(
      generation: UUID(), expectedPeer: MCPeerID(displayName: "Mac")
    ) {
      _, event in
      count += 1
      if case .unsupportedTransfer = event { failures += 1 }
    }
    for _ in 0..<3 { delegate.enqueue(.data(value: Data(repeating: 0, count: 90_000))) }
    await Task.yield()
    XCTAssertEqual(count, 1)
    XCTAssertEqual(failures, 1)
  }

  func testTeardownDropsPendingEventsAndDoesNotPublishAfterStop() async {
    var count = 0
    let delegate = NearbySessionDelegate(
      generation: UUID(), expectedPeer: MCPeerID(displayName: "Mac")
    ) {
      _, _ in count += 1
    }
    delegate.enqueue(.data(value: Data([1])))
    delegate.invalidate()
    delegate.enqueue(.unsupportedTransfer)
    await Task.yield()
    XCTAssertEqual(count, 0)
  }

  func testSameDisplayNameIsNotAcceptedAsPeerIdentity() async {
    let expected = MCPeerID(displayName: "Same Name")
    let stranger = MCPeerID(displayName: "Same Name")
    XCTAssertNotEqual(expected, stranger)
    var failures = 0
    let delegate = NearbySessionDelegate(generation: UUID(), expectedPeer: expected) { _, event in
      if case .unsupportedTransfer = event { failures += 1 }
    }
    let session = MCSession(
      peer: MCPeerID(displayName: "Fixture"), securityIdentity: nil, encryptionPreference: .required
    )
    delegate.session(session, didReceive: Data([1]), fromPeer: stranger)
    await Task.yield()
    XCTAssertEqual(failures, 1)
    delegate.invalidate()
    session.disconnect()
  }
}
