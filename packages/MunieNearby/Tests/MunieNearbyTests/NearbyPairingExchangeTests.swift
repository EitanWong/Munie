import Foundation
import XCTest

@testable import MunieNearby

final class NearbyPairingExchangeTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func connected() throws -> (NearbyPairingExchange, NearbyPairingExchange) {
    let id = UUID()
    var host = try NearbyPairingExchange(role: .host, requestID: id, name: "Test Mac", now: now)
    var client = try NearbyPairingExchange(
      role: .client, requestID: id, name: "Test iPhone", now: now)
    let hostCommitment = try host.commitment(now: now)
    let clientCommitment = try client.commitment(now: now)
    let clientReveal = try XCTUnwrap(client.receiveHandshake(hostCommitment, now: now))
    let hostReveal = try XCTUnwrap(host.receiveHandshake(clientCommitment, now: now))
    XCTAssertNil(try host.receiveHandshake(clientReveal, now: now))
    XCTAssertNil(try client.receiveHandshake(hostReveal, now: now))
    return (host, client)
  }

  func testBothPeersComputeSameBoundCodeAndDoNotTransmitIt() throws {
    let (host, client) = try connected()
    let code = try XCTUnwrap(host.verificationCode)
    XCTAssertEqual(code.count, 6)
    XCTAssertEqual(host.verificationCode, client.verificationCode)
    XCTAssertEqual(host.remoteName, "Test iPhone")
    XCTAssertEqual(client.remoteName, "Test Mac")
    XCTAssertFalse(String(decoding: try host.commitment(now: now), as: UTF8.self).contains(code))
  }

  func testHostNeverReleasesPayloadWithoutBothUserConfirmations() throws {
    var (host, client) = try connected()
    let payload = Data("real-structured-pairing-fixture".utf8)
    XCTAssertThrowsError(try host.sealPayload(payload, now: now))
    _ = try host.confirm(now: now)
    XCTAssertThrowsError(try host.sealPayload(payload, now: now))
    let confirmation = try XCTUnwrap(client.confirm(now: now))
    XCTAssertNil(try host.receiveHandshake(confirmation, now: now))
    let sealed = try host.sealPayload(payload, now: now)
    XCTAssertFalse(sealed.range(of: payload) != nil)
    XCTAssertEqual(try client.openPayload(sealed, now: now), payload)
    XCTAssertThrowsError(try host.sealPayload(payload, now: now))
    XCTAssertThrowsError(try client.openPayload(sealed, now: now))
  }

  func testPhoneConfirmationAloneCannotReleasePayload() throws {
    var (host, client) = try connected()
    let confirmation = try XCTUnwrap(client.confirm(now: now))
    _ = try host.receiveHandshake(confirmation, now: now)
    XCTAssertThrowsError(try host.sealPayload(Data([1]), now: now))
    _ = try host.confirm(now: now)
    XCTAssertEqual(
      try client.openPayload(host.sealPayload(Data([1]), now: now), now: now), Data([1]))
  }

  func testForgedRevealIsRejectedAfterCommitment() throws {
    let id = UUID()
    var host = try NearbyPairingExchange(role: .host, requestID: id, name: "Mac", now: now)
    var client = try NearbyPairingExchange(role: .client, requestID: id, name: "Phone", now: now)
    let reveal = try XCTUnwrap(client.receiveHandshake(host.commitment(now: now), now: now))
    _ = try host.receiveHandshake(client.commitment(now: now), now: now)
    let message = try JSONDecoder().decode(NearbyPairingExchange.Message.self, from: reveal)
    let altered = NearbyPairingExchange.Message(
      version: 1, requestID: id, kind: .reveal, body: message.body + Data([0]))
    XCTAssertThrowsError(try host.receiveHandshake(JSONEncoder().encode(altered), now: now))
  }

  func testForeignRequestAndVersionAndOversizeAreRejected() throws {
    var (host, _) = try connected()
    for message in [
      NearbyPairingExchange.Message(
        version: 1, requestID: UUID(), kind: .confirmation, body: Data()),
      NearbyPairingExchange.Message(
        version: 2, requestID: host.requestID, kind: .confirmation, body: Data()),
    ] {
      XCTAssertThrowsError(try host.receiveHandshake(JSONEncoder().encode(message), now: now))
    }
    XCTAssertThrowsError(try host.receiveHandshake(Data(repeating: 0, count: 90_001), now: now))
  }

  func testDuplicateCommitmentAndConfirmationAreRejected() throws {
    let id = UUID()
    var host = try NearbyPairingExchange(role: .host, requestID: id, name: "Mac", now: now)
    let client = try NearbyPairingExchange(role: .client, requestID: id, name: "Phone", now: now)
    let commitment = try client.commitment(now: now)
    _ = try host.receiveHandshake(commitment, now: now)
    XCTAssertThrowsError(try host.receiveHandshake(commitment, now: now))
    var (connectedHost, connectedClient) = try connected()
    let confirmation = try XCTUnwrap(connectedClient.confirm(now: now))
    _ = try connectedHost.receiveHandshake(confirmation, now: now)
    XCTAssertThrowsError(try connectedHost.receiveHandshake(confirmation, now: now))
  }

  func testExpiryAppliesToConfirmationAndPayload() throws {
    var (host, client) = try connected()
    let expired = now.addingTimeInterval(120)
    XCTAssertThrowsError(try host.confirm(now: expired))
    XCTAssertThrowsError(try client.confirm(now: expired))
    XCTAssertThrowsError(try host.commitment(now: expired))
  }

  func testTamperedCiphertextAndOtherSessionsCannotDecrypt() throws {
    var (host, client) = try connected()
    _ = try host.confirm(now: now)
    _ = try host.receiveHandshake(XCTUnwrap(client.confirm(now: now)), now: now)
    let sealed = try host.sealPayload(Data("secret".utf8), now: now)
    let message = try JSONDecoder().decode(NearbyPairingExchange.Message.self, from: sealed)
    var body = message.body
    body[body.count - 1] ^= 1
    let tampered = NearbyPairingExchange.Message(
      version: 1, requestID: host.requestID, kind: .payload, body: body)
    XCTAssertThrowsError(try client.openPayload(JSONEncoder().encode(tampered), now: now))
    XCTAssertEqual(try client.openPayload(sealed, now: now), Data("secret".utf8))
    var (_, otherClient) = try connected()
    _ = try otherClient.confirm(now: now)
    XCTAssertThrowsError(try otherClient.openPayload(sealed, now: now))
  }

  func testUnconfirmedClientCannotAcceptPayloadAndPayloadIsBounded() throws {
    var (host, client) = try connected()
    XCTAssertThrowsError(try client.openPayload(Data(), now: now))
    _ = try host.confirm(now: now)
    _ = try host.receiveHandshake(XCTUnwrap(client.confirm(now: now)), now: now)
    XCTAssertThrowsError(try host.sealPayload(Data(repeating: 1, count: 65_537), now: now))
    XCTAssertThrowsError(try host.sealPayload(Data(), now: now))
    let maximum = Data(repeating: 7, count: 65_536)
    XCTAssertEqual(try client.openPayload(host.sealPayload(maximum, now: now), now: now), maximum)
  }

  func testNamesRejectControlCharactersAndUnboundedInput() throws {
    for invalid in ["", " \n", "Mac\nspoof", String(repeating: "a", count: 64)] {
      XCTAssertThrowsError(
        try NearbyPairingExchange(
          role: .host, requestID: UUID(), name: invalid, now: now))
    }
  }

  @MainActor func testStopClearsPublishedStateWithoutStartingRadio() {
    let host = NearbyPairingHost()
    host.stop()
    XCTAssertEqual(host.state, .idle)
    XCTAssertNil(host.pendingRequest)
    let client = NearbyPairingClient()
    client.stop()
    XCTAssertEqual(client.state, .idle)
    XCTAssertTrue(client.discoveredHosts.isEmpty)
    XCTAssertNil(client.verificationCode)
    XCTAssertNil(client.receivedPayload)
  }
}
