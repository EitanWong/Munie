import Foundation
import XCTest

@testable import MunieRemodex

final class NearbyPairingPayloadValidatorTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func payload() -> [String: Any] {
    [
      "v": 2,
      "relay": "ws://192.168.1.2:49271/relay",
      "sessionId": "63BC8D08-0B6D-4C9D-89A5-41D3B06B64D0",
      "macDeviceId": "test-mac-device",
      "macIdentityPublicKey": Data(repeating: 3, count: 32).base64EncodedString(),
      "expiresAt": Int64(now.addingTimeInterval(120).timeIntervalSince1970 * 1_000),
      "displayName": "Fixture Mac",
    ]
  }

  func testPreservesActualStructuredTrustAndTransportFields() throws {
    let data = try JSONSerialization.data(withJSONObject: payload())
    let actual = try NearbyPairingPayloadValidator.decode(data, now: now)
    XCTAssertEqual(actual.v, 2)
    XCTAssertEqual(actual.relay, "ws://192.168.1.2:49271/relay")
    XCTAssertEqual(actual.sessionId, payload()["sessionId"] as? String)
    XCTAssertEqual(actual.macDeviceId, "test-mac-device")
    XCTAssertEqual(actual.macIdentityPublicKey, payload()["macIdentityPublicKey"] as? String)
    XCTAssertEqual(actual.expiresAt, payload()["expiresAt"] as? Int64)
    XCTAssertEqual(actual.displayName, "Fixture Mac")
  }

  func testRejectsExpiredWrongVersionMalformedIdentityAndUnsafeEndpoint() throws {
    let cases: [(String, Any)] = [
      ("v", 1), ("expiresAt", Int64(now.timeIntervalSince1970 * 1_000)),
      ("macIdentityPublicKey", "not-a-key"), ("macDeviceId", ""), ("sessionId", "../another"),
      ("relay", "https://example.test/relay"), ("relay", "ws://user:password@example.test/relay"),
      ("relay", "ws://example.test/relay?token=secret"),
    ]
    for (key, value) in cases {
      var changed = payload()
      changed[key] = value
      let data = try JSONSerialization.data(withJSONObject: changed)
      XCTAssertThrowsError(try NearbyPairingPayloadValidator.decode(data, now: now), key)
    }
    XCTAssertThrowsError(
      try NearbyPairingPayloadValidator.decode(Data(repeating: 0, count: 65_537)))
  }
}
