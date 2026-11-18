// Munie modification: nearby approval hands the existing secure transport an exact v2 payload.
import Foundation

enum NearbyPairingPayloadValidator {
  static func decode(_ data: Data, now: Date = Date()) throws -> CodexPairingQRPayload {
    guard !data.isEmpty, data.count <= 65_536 else { throw ValidationError.invalid }
    let payload = try JSONDecoder().decode(CodexPairingQRPayload.self, from: data)
    guard payload.v == codexPairingQRVersion,
      let url = URLComponents(string: payload.relay),
      ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host, !host.isEmpty,
      url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
      !payload.sessionId.isEmpty, payload.sessionId.utf8.count <= 256,
      !payload.sessionId.contains("/"), !payload.sessionId.contains("?"),
      !payload.sessionId.contains("#"),
      !payload.macDeviceId.isEmpty, payload.macDeviceId.utf8.count <= 256,
      Data(base64Encoded: payload.macIdentityPublicKey)?.count == 32,
      TimeInterval(payload.expiresAt) / 1_000 > now.timeIntervalSince1970
    else { throw ValidationError.invalid }
    return payload
  }

  enum ValidationError: Error { case invalid }
}
