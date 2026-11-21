import CryptoKit
import Foundation

/// Codec for the reconnect-only loopback pilot. The caller supplies the already selected trust record.
nonisolated struct ManagedRelayPhoneAdmission: Sendable {
  static let audience = "munie-loopback.invalid"
  static let maximumChallengeBytes = 1024

  private static let role = "phone"
  private static let transcriptTag = "munie-managed-relay-admission-v1"
  private static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
  // Match the managed Mac client: 15 seconds of relay lifetime plus up to 5 seconds of clock skew.
  private static let maximumRemainingLifetime: Int64 = 20_000

  enum ValidationError: Error, Equatable {
    case invalidPhoneIdentity
    case invalidTrustedMacKey
    case malformedChallenge
    case challengeMismatch
    case invalidExpiry
  }

  struct Proof: Equatable, Sendable {
    let challengeID: String
    let signature: String

    var upgradeHeaders: [String: String] {
      [
        "x-munie-role": ManagedRelayPhoneAdmission.role,
        "x-munie-challenge": challengeID,
        "x-munie-proof": signature,
      ]
    }
  }

  let phoneKey: String
  let macKey: String
  private let phonePrivateKey: Curve25519.Signing.PrivateKey

  init(identity: CodexPhoneIdentityState, trustedMac: CodexTrustedMacRecord) throws {
    guard let rawPrivateKey = Self.decodeStoredKey(identity.phoneIdentityPrivateKey),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey),
      let storedPublicKey = Self.decodeStoredKey(identity.phoneIdentityPublicKey),
      storedPublicKey == privateKey.publicKey.rawRepresentation
    else {
      throw ValidationError.invalidPhoneIdentity
    }
    guard let trustedMacKey = Self.decodeStoredKey(trustedMac.macIdentityPublicKey) else {
      throw ValidationError.invalidTrustedMacKey
    }
    phonePrivateKey = privateKey
    phoneKey = Self.encodeBase64URL(privateKey.publicKey.rawRepresentation)
    macKey = Self.encodeBase64URL(trustedMacKey)
  }

  func challengeRequestBody() throws -> Data {
    try JSONEncoder().encode(ChallengeRequest(role: Self.role, macKey: macKey, phoneKey: phoneKey))
  }

  /// Validate immediately before signing. The relay owns single use and generation validity.
  func proof(
    for response: Data,
    nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
  ) throws -> Proof {
    guard response.count <= Self.maximumChallengeBytes,
      !response.contains(0), String(data: response, encoding: .utf8) != nil,
      let challenge = try? JSONDecoder().decode(Challenge.self, from: response),
      Self.isCanonicalToken(challenge.id), Self.isCanonicalToken(challenge.generation)
    else {
      throw ValidationError.malformedChallenge
    }
    guard challenge.audience == Self.audience, challenge.role == Self.role,
      challenge.macKey == macKey, challenge.phoneKey == phoneKey
    else {
      throw ValidationError.challengeMismatch
    }
    guard nowMilliseconds >= 0, challenge.expiresAt <= Self.maximumSafeInteger,
      challenge.expiresAt > nowMilliseconds,
      challenge.expiresAt - nowMilliseconds <= Self.maximumRemainingLifetime
    else {
      throw ValidationError.invalidExpiry
    }

    // All strings are fixed ASCII or canonical base64url. This unkeyed JSON array matches
    // JSON.stringify exactly, including the final integer (not a quoted string).
    let transcript = try JSONEncoder().encode(Transcript(challenge: challenge))
    let signature = try phonePrivateKey.signature(for: transcript)
    return Proof(challengeID: challenge.id, signature: Self.encodeBase64URL(signature))
  }

  private struct ChallengeRequest: Encodable {
    let role: String
    let macKey: String
    let phoneKey: String
  }

  private struct Challenge: Decodable {
    let audience: String
    let role: String
    let macKey: String
    let phoneKey: String
    let id: String
    let generation: String
    let expiresAt: Int64
  }

  private struct Transcript: Encodable {
    let challenge: Challenge

    func encode(to encoder: any Encoder) throws {
      var fields = encoder.unkeyedContainer()
      try fields.encode(ManagedRelayPhoneAdmission.transcriptTag)
      try fields.encode(challenge.audience)
      try fields.encode(challenge.role)
      try fields.encode(challenge.macKey)
      try fields.encode(challenge.phoneKey)
      try fields.encode(challenge.id)
      try fields.encode(challenge.generation)
      try fields.encode(challenge.expiresAt)
    }
  }

  private static func decodeStoredKey(_ value: String) -> Data? {
    guard value.utf8.count == 44, let bytes = Data(base64Encoded: value),
      bytes.count == 32, bytes.base64EncodedString() == value
    else { return nil }
    return bytes
  }

  private static func isCanonicalToken(_ value: String) -> Bool {
    guard value.utf8.count == 43 else { return false }
    let padded =
      value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/") + "="
    guard let bytes = Data(base64Encoded: padded), bytes.count == 32 else { return false }
    return encodeBase64URL(bytes) == value
  }

  private static func encodeBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
