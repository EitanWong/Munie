import CryptoKit
import Foundation
import XCTest

@testable import MunieRemodex

final class ManagedRelayPhoneAdmissionTests: XCTestCase {
  private let now: Int64 = 1_700_000_000_000
  private let macKey = "Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc"
  private let phoneKey = "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"
  private let challengeID = "-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_s"
  private let generation = "__________________________________________8"
  private let nodeSignature =
    "L24N-Z5K1ETRzBMKIJu4xLxitUjf4xtLucY_XXAIxy9qvHXBFsME3Kpu6NFMJ41k-xjut9kLgMu-Mr52H3ezBg"

  func testNodeVectorAndWireFields() throws {
    let credential = try credential()
    XCTAssertEqual(credential.phoneKey, phoneKey)
    XCTAssertEqual(credential.macKey, macKey)
    let request = try JSONDecoder().decode(
      [String: String].self, from: credential.challengeRequestBody())
    XCTAssertEqual(request, ["role": "phone", "macKey": macKey, "phoneKey": phoneKey])

    let proof = try credential.proof(for: challenge(), nowMilliseconds: now)
    XCTAssertEqual(
      proof.upgradeHeaders,
      [
        "x-munie-role": "phone", "x-munie-challenge": challengeID, "x-munie-proof": proof.signature,
      ])
    let transcript =
      "[\"munie-managed-relay-admission-v1\",\"munie-loopback.invalid\",\"phone\","
      + "\"\(macKey)\",\"\(phoneKey)\",\"\(challengeID)\",\"\(generation)\",1700000015000]"
    let publicKey = try signingKey(start: 0).publicKey
    // Node signed the literal transcript with seed 00...1f. CryptoKit may emit a different valid signature.
    for signature in [nodeSignature, proof.signature] {
      let bytes = try decodeBase64URL(signature)
      XCTAssertEqual(bytes.count, 64)
      XCTAssertEqual(
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
          .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
        signature)
      XCTAssertTrue(publicKey.isValidSignature(bytes, for: Data(transcript.utf8)))
    }
  }

  func testRejectsMismatchedScopeAndIdentities() throws {
    let credential = try credential()
    for patch in [
      ["audience": "fixture.invalid"], ["role": "mac"], ["role": "iPhone"],
      ["macKey": phoneKey], ["phoneKey": macKey], ["phoneKey": phoneKey + "="],
    ] {
      XCTAssertThrowsError(try credential.proof(for: challenge(patch), nowMilliseconds: now)) {
        XCTAssertEqual($0 as? ManagedRelayPhoneAdmission.ValidationError, .challengeMismatch)
      }
    }
  }

  func testRejectsExpiredAndExcessivelyFutureChallenges() throws {
    let credential = try credential()
    for expiry in [now - 1, now, now + 20_001, 9_007_199_254_740_992] {
      XCTAssertThrowsError(
        try credential.proof(for: challenge(["expiresAt": expiry]), nowMilliseconds: now)
      ) {
        XCTAssertEqual($0 as? ManagedRelayPhoneAdmission.ValidationError, .invalidExpiry)
      }
    }
    for expiry in [now + 1, now + 20_000] {
      XCTAssertNoThrow(
        try credential.proof(for: challenge(["expiresAt": expiry]), nowMilliseconds: now))
    }
  }

  func testRejectsMalformedAndNoncanonicalChallenges() throws {
    let credential = try credential()
    let cases: [[String: Any]] = [
      ["generation": ""], ["generation": NSNull()], ["generation": generation + "="],
      ["id": challengeID + "="], ["id": String(challengeID.dropLast()) + "t"],
      ["id": challengeID.replacingOccurrences(of: "-", with: "+")],
      ["expiresAt": "1700000015000"], ["expiresAt": 1_700_000_015_000.5],
    ]
    for patch in cases {
      XCTAssertThrowsError(try credential.proof(for: challenge(patch), nowMilliseconds: now)) {
        XCTAssertEqual($0 as? ManagedRelayPhoneAdmission.ValidationError, .malformedChallenge)
      }
    }

    let valid = try challenge()
    let text = try XCTUnwrap(String(data: valid, encoding: .utf8))
    let oversized =
      valid + Data(repeating: 0x20, count: ManagedRelayPhoneAdmission.maximumChallengeBytes)
    let noGeneration = try challenge(omitting: "generation")
    for malformed in [
      Data("[]".utf8), Data([0xFF]),
      Data(
        text.utf16.flatMap {
          [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
        }), noGeneration, oversized,
    ] {
      XCTAssertThrowsError(try credential.proof(for: malformed, nowMilliseconds: now)) {
        XCTAssertEqual($0 as? ManagedRelayPhoneAdmission.ValidationError, .malformedChallenge)
      }
    }
  }

  func testRejectsMalformedOrInconsistentStoredKeys() throws {
    let phone = try signingKey(start: 0)
    let mac = try signingKey(start: 32)
    let macStoredPublicKey = mac.publicKey.rawRepresentation.base64EncodedString()
    let valid = try identity()
    for malformed in [
      CodexPhoneIdentityState(
        phoneDeviceId: valid.phoneDeviceId, phoneIdentityPrivateKey: "bad",
        phoneIdentityPublicKey: valid.phoneIdentityPublicKey
      ),
      CodexPhoneIdentityState(
        phoneDeviceId: valid.phoneDeviceId, phoneIdentityPrivateKey: valid.phoneIdentityPrivateKey,
        phoneIdentityPublicKey: macStoredPublicKey
      ),
      CodexPhoneIdentityState(
        phoneDeviceId: valid.phoneDeviceId,
        phoneIdentityPrivateKey: phone.rawRepresentation.base64EncodedString(),
        phoneIdentityPublicKey: phoneKey
      ),
    ] {
      XCTAssertThrowsError(
        try ManagedRelayPhoneAdmission(
          identity: malformed, trustedMac: trustedMac(macStoredPublicKey))
      ) {
        XCTAssertEqual($0 as? ManagedRelayPhoneAdmission.ValidationError, .invalidPhoneIdentity)
      }
    }
    for malformed in [macKey, macStoredPublicKey + "=", ""] {
      XCTAssertThrowsError(
        try ManagedRelayPhoneAdmission(identity: valid, trustedMac: trustedMac(malformed))
      ) {
        XCTAssertEqual($0 as? ManagedRelayPhoneAdmission.ValidationError, .invalidTrustedMacKey)
      }
    }
  }

  private func credential() throws -> ManagedRelayPhoneAdmission {
    let mac = try signingKey(start: 32)
    return try ManagedRelayPhoneAdmission(
      identity: identity(),
      trustedMac: trustedMac(mac.publicKey.rawRepresentation.base64EncodedString()))
  }

  private func identity() throws -> CodexPhoneIdentityState {
    let phone = try signingKey(start: 0)
    return CodexPhoneIdentityState(
      phoneDeviceId: "fixture-phone",
      phoneIdentityPrivateKey: phone.rawRepresentation.base64EncodedString(),
      phoneIdentityPublicKey: phone.publicKey.rawRepresentation.base64EncodedString()
    )
  }

  private func trustedMac(_ storedKey: String) -> CodexTrustedMacRecord {
    CodexTrustedMacRecord(
      macDeviceId: "fixture-mac", macIdentityPublicKey: storedKey,
      lastPairedAt: Date(timeIntervalSince1970: 0))
  }

  private func signingKey(start: Int) throws -> Curve25519.Signing.PrivateKey {
    try Curve25519.Signing.PrivateKey(
      rawRepresentation: Data((start..<(start + 32)).map(UInt8.init)))
  }

  private func challenge(_ patch: [String: Any] = [:], omitting key: String? = nil) throws -> Data {
    var fields: [String: Any] = [
      "audience": "munie-loopback.invalid", "role": "phone", "macKey": macKey, "phoneKey": phoneKey,
      "id": challengeID, "generation": generation, "expiresAt": now + 15_000,
    ]
    fields.merge(patch) { _, replacement in replacement }
    if let key { fields.removeValue(forKey: key) }
    return try JSONSerialization.data(withJSONObject: fields)
  }

  private func decodeBase64URL(_ value: String) throws -> Data {
    try XCTUnwrap(
      Data(
        base64Encoded: value.replacingOccurrences(of: "-", with: "+")
          .replacingOccurrences(of: "_", with: "/") + "=="))
  }
}
