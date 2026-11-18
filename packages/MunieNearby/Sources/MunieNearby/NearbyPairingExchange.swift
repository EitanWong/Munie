import CryptoKit
import Foundation

public enum NearbyPairingError: Error, Equatable, Sendable {
  case invalidMessage
  case expired
  case invalidState
  case confirmationRequired
  case payloadTooLarge
  case transportUnavailable
}

/// A one-use, bounded exchange. The short authentication string is never transmitted.
/// Each peer commits to its ephemeral key and nonce before either reveals them.
/// Both users must compare the displayed code; encryption alone does not establish identity.
struct NearbyPairingExchange {
  enum Role: String, Codable, Sendable { case host, client }
  struct Hello: Codable {
    let role: Role
    let requestID: UUID
    let name: String
    let publicKey: Data
    let nonce: Data
  }
  struct Message: Codable {
    enum Kind: String, Codable { case commitment, reveal, confirmation, payload }
    let version: Int
    let requestID: UUID
    let kind: Kind
    let body: Data
  }

  static let maximumPayloadBytes = 65_536
  static let maximumMessageBytes = 90_000
  static let lifetime: TimeInterval = 120
  private let role: Role
  let requestID: UUID
  private let privateKey: P256.KeyAgreement.PrivateKey
  private let localHello: Data
  private let deadline: Date
  private var peerCommitment: Data?
  private var peerHello: Data?
  private var key: SymmetricKey?
  private var transcript: Data?
  private(set) var verificationCode: String?
  private(set) var remoteName: String?
  private(set) var localConfirmed = false
  private(set) var remoteConfirmed = false
  private(set) var consumed = false

  init(role: Role, requestID: UUID, name: String, now: Date = Date()) throws {
    guard Self.validName(name) else { throw NearbyPairingError.invalidMessage }
    self.role = role
    self.requestID = requestID
    deadline = now.addingTimeInterval(Self.lifetime)
    privateKey = P256.KeyAgreement.PrivateKey()
    var generator = SystemRandomNumberGenerator()
    let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    localHello = try Self.encode(
      Hello(
        role: role, requestID: requestID, name: name,
        publicKey: privateKey.publicKey.x963Representation, nonce: nonce))
  }

  func commitment(now: Date = Date()) throws -> Data {
    try checkTime(now)
    return try message(.commitment, body: Data(SHA256.hash(data: localHello)))
  }

  /// Returns the next wire message, if any. Payload is accepted through `openPayload` only.
  mutating func receiveHandshake(_ data: Data, now: Date = Date()) throws -> Data? {
    try checkTime(now)
    let incoming = try decode(data)
    switch incoming.kind {
    case .commitment:
      guard peerCommitment == nil, incoming.body.count == 32 else {
        throw NearbyPairingError.invalidState
      }
      peerCommitment = incoming.body
      return try message(.reveal, body: localHello)
    case .reveal:
      guard let peerCommitment, peerHello == nil,
        Data(SHA256.hash(data: incoming.body)) == peerCommitment
      else { throw NearbyPairingError.invalidMessage }
      let hello = try JSONDecoder().decode(Hello.self, from: incoming.body)
      guard hello.role != role, hello.requestID == requestID,
        Self.validName(hello.name), hello.nonce.count == 32, hello.publicKey.count == 65
      else { throw NearbyPairingError.invalidMessage }
      let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: hello.publicKey)
      let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
      let hostHello = role == .host ? localHello : incoming.body
      let clientHello = role == .client ? localHello : incoming.body
      var context = Data("Munie nearby pairing v1\0".utf8)
      context.append(hostHello)
      context.append(0)
      context.append(clientHello)
      let digest = Data(SHA256.hash(data: context))
      transcript = digest
      key = secret.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: digest, sharedInfo: Data("payload".utf8), outputByteCount: 32)
      let codeKey = secret.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: digest, sharedInfo: Data("comparison".utf8), outputByteCount: 4)
      let number =
        codeKey.withUnsafeBytes { bytes in
          bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        } % 1_000_000
      verificationCode = String(format: "%06u", number)
      remoteName = hello.name
      peerHello = incoming.body
      return nil
    case .confirmation:
      guard role == .host, !remoteConfirmed else { throw NearbyPairingError.invalidState }
      let plaintext = try open(incoming.body)
      guard plaintext == Data("client-confirmed".utf8) else {
        throw NearbyPairingError.invalidMessage
      }
      remoteConfirmed = true
      return nil
    case .payload:
      throw NearbyPairingError.invalidState
    }
  }

  mutating func confirm(now: Date = Date()) throws -> Data? {
    try checkTime(now)
    guard verificationCode != nil, !localConfirmed, !consumed else {
      throw NearbyPairingError.invalidState
    }
    localConfirmed = true
    if role == .client {
      return try message(.confirmation, body: seal(Data("client-confirmed".utf8)))
    }
    return nil
  }

  mutating func sealPayload(_ payload: Data, now: Date = Date()) throws -> Data {
    try checkTime(now)
    guard role == .host, localConfirmed, remoteConfirmed, !consumed else {
      throw NearbyPairingError.confirmationRequired
    }
    guard !payload.isEmpty, payload.count <= Self.maximumPayloadBytes else {
      throw NearbyPairingError.payloadTooLarge
    }
    let result = try message(.payload, body: seal(payload))
    consumed = true
    return result
  }

  mutating func openPayload(_ data: Data, now: Date = Date()) throws -> Data {
    try checkTime(now)
    guard role == .client, localConfirmed, !consumed else {
      throw NearbyPairingError.confirmationRequired
    }
    let incoming = try decode(data)
    guard incoming.kind == .payload else { throw NearbyPairingError.invalidMessage }
    let result = try open(incoming.body)
    guard !result.isEmpty, result.count <= Self.maximumPayloadBytes else {
      throw NearbyPairingError.payloadTooLarge
    }
    consumed = true
    return result
  }

  private func checkTime(_ now: Date) throws {
    guard now < deadline else { throw NearbyPairingError.expired }
  }

  private func decode(_ data: Data) throws -> Message {
    guard data.count <= Self.maximumMessageBytes else { throw NearbyPairingError.payloadTooLarge }
    let decoded = try JSONDecoder().decode(Message.self, from: data)
    guard decoded.version == 1, decoded.requestID == requestID else {
      throw NearbyPairingError.invalidMessage
    }
    return decoded
  }

  private func message(_ kind: Message.Kind, body: Data) throws -> Data {
    try Self.encode(Message(version: 1, requestID: requestID, kind: kind, body: body))
  }

  private func seal(_ data: Data) throws -> Data {
    guard let key, let transcript else { throw NearbyPairingError.invalidState }
    guard let combined = try AES.GCM.seal(data, using: key, authenticating: transcript).combined
    else {
      throw NearbyPairingError.invalidMessage
    }
    return combined
  }

  private func open(_ data: Data) throws -> Data {
    guard let key, let transcript else { throw NearbyPairingError.invalidState }
    return try AES.GCM.open(
      AES.GCM.SealedBox(combined: data), using: key, authenticating: transcript)
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  static func validName(_ name: String) -> Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && name.utf8.count <= 63
      && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}
