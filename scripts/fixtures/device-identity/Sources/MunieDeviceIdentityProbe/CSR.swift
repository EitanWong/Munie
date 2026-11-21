import Foundation
import Security
import SwiftASN1
import X509

enum MunieCSRError: Error, Equatable, Sendable {
  case invalidPrivateKey
  case invalidP256Key
  case invalidCommonName
}

/// PKCS#10 encoding for a caller-owned private P-256 SecKey.
/// This module never exports or persists the private key and does not query a keychain.
enum MunieCSR {
  /// Creates a signed DER CSR. The caller controls the key lifetime and access policy.
  static func makeDER(privateKey: SecKey, commonName: String) throws -> Data {
    guard !commonName.isEmpty, commonName.utf8.count <= 64,
      !commonName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw MunieCSRError.invalidCommonName }
    guard let attributes = SecKeyCopyAttributes(privateKey) as? [CFString: Any],
      let keyClass = attributes[kSecAttrKeyClass] as? String,
      keyClass == (kSecAttrKeyClassPrivate as String)
    else { throw MunieCSRError.invalidPrivateKey }
    guard let keyType = attributes[kSecAttrKeyType] as? String,
      keyType == (kSecAttrKeyTypeECSECPrimeRandom as String),
      (attributes[kSecAttrKeySizeInBits] as? NSNumber)?.intValue == 256
    else { throw MunieCSRError.invalidP256Key }
    let signingKey = try Certificate.PrivateKey(privateKey)
    let request = try CertificateSigningRequest(
      version: .v1,
      subject: DistinguishedName { CommonName(commonName) },
      privateKey: signingKey,
      attributes: .init(),
      signatureAlgorithm: .ecdsaWithSHA256
    )
    var serializer = DER.Serializer()
    try serializer.serialize(request)
    return Data(serializer.serializedBytes)
  }
}
