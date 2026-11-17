import Crypto
import Foundation
import Security
import SwiftASN1
import X509

enum IdentityResearch {
  static func run(arguments: [String]) {
    let zeroID = "00000000-0000-0000-0000-000000000000"
    var report = ResearchReport(runID: zeroID, phase: "invalid", nonce: zeroID)
    do {
      let files = try ResearchFiles()
      var parsedInput: ResearchInput?
      do {
        let input = try ResearchInput.parse(arguments)
        parsedInput = input
        report = ResearchReport(runID: input.runID, phase: input.phase.rawValue, nonce: input.nonce)
        files.recordProgress(.phaseStarted, input: input)
        try execute(input, files: files, report: &report)
        report.passed = true
      } catch let failure as ResearchFailure {
        report.failure = failure.code
        report.osStatus = failure.osStatus
      } catch {
        report.failure = "unexpected-failure"
      }
      try files.saveReport(report)
      if let parsedInput { files.recordProgress(.reportSaved, input: parsedInput) }
    } catch {
      // The report cannot be safely delivered; the runner must fail on missing/stale nonce.
      print("identity-research-report-unavailable")
    }
  }

  private static func execute(
    _ input: ResearchInput, files: ResearchFiles, report: inout ResearchReport
  ) throws {
    switch input.phase {
    case .create:
      guard !FileManager.default.fileExists(atPath: files.manifestURL.path) else {
        throw ResearchFailure("manifest-already-exists")
      }
      var manifest = ResearchManifest(runID: input.runID)
      try manifest.validate(runID: input.runID)
      // Planning a tag does not claim an existing item. Each add is journaled separately.
      try files.saveManifest(manifest)
      try createIdentity(role: .target, manifest: &manifest, files: files, fault: input.fault)
      try createIdentity(role: .control, manifest: &manifest, files: files, fault: nil)
      try verify(manifest.target, nonce: input.nonce)
      try verify(manifest.control, nonce: input.nonce)
      try rejectMismatchedIdentity(manifest.target)
      setIdentityChecks(&report)
      report.checks["mismatchedIdentityRejected"] = .flag(true)
      report.checks["controlStillUsable"] = .flag(true)
    case .reopen:
      let manifest = try files.loadManifest(runID: input.runID)
      // Reopen never creates keys, certificates, tags or replacement references.
      try verify(manifest.target, nonce: input.nonce)
      try verify(manifest.control, nonce: input.nonce)
      setIdentityChecks(&report)
      report.checks["controlStillUsable"] = .flag(true)
    case .delete:
      let manifest = try files.loadManifest(runID: input.runID)
      try verify(manifest.target, nonce: input.nonce)
      let certificateReference = try requiredReference(manifest.target.certificatePersistentRef)
      let keyReference = try requiredReference(manifest.target.keyPersistentRef)
      let certificateStatus = deleteReference(certificateReference, itemClass: kSecClassCertificate)
      report.checks["certificateDeleteStatus"] = .status(Int(certificateStatus))
      try requireSuccess(certificateStatus, "certificate-delete-failed")
      let keyStatus = deleteReference(keyReference, itemClass: kSecClassKey)
      report.checks["keyDeleteStatus"] = .status(Int(keyStatus))
      try requireSuccess(keyStatus, "key-delete-failed")
      try confirmDeleted(manifest.target, report: &report)
      try verify(manifest.control, nonce: input.nonce)
      report.checks["controlStillUsable"] = .flag(true)
    case .confirmDeleted:
      let manifest = try files.loadManifest(runID: input.runID)
      try confirmDeleted(manifest.target, report: &report)
      try verify(manifest.control, nonce: input.nonce)
      report.checks["controlStillUsable"] = .flag(true)
    case .cleanup:
      let manifest = try files.loadManifest(runID: input.runID)
      // Cleanup also handles a create interrupted before a persistent reference was saved.
      var firstFailure: ResearchFailure?
      for identity in [manifest.target, manifest.control] {
        do {
          try cleanup(identity)
        } catch let failure as ResearchFailure {
          if firstFailure == nil { firstFailure = failure }
        } catch {
          if firstFailure == nil { firstFailure = ResearchFailure("cleanup-unexpected-failure") }
        }
      }
      if let firstFailure { throw firstFailure }
      do {
        try FileManager.default.removeItem(at: files.manifestURL)
      } catch {
        throw ResearchFailure("manifest-delete-failed")
      }
      report.checks["cleanupOwnItems"] = .flag(true)
    }
  }

  private static func setIdentityChecks(_ report: inout ResearchReport) {
    for name in [
      "keyPublicMatched", "identityLeafMatched", "identityPossessionVerified",
      "privateKeyPermanent", "certificatePresent",
    ] {
      report.checks[name] = .flag(true)
    }
  }

  private enum Role { case target, control }

  private static func save(
    _ identity: OwnedIdentity, role: Role, manifest: inout ResearchManifest, files: ResearchFiles
  ) throws {
    switch role {
    case .target: manifest.target = identity
    case .control: manifest.control = identity
    }
    try files.saveManifest(manifest)
  }

  private static func createIdentity(
    role: Role, manifest: inout ResearchManifest, files: ResearchFiles, fault: ResearchFault?
  ) throws {
    var identity = role == .target ? manifest.target : manifest.control
    // Generate in memory first, so recovery can require a known public-key hash even
    // if the process stops after SecItemAdd succeeds but before its ref is journaled.
    let parameters: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits: 256,
      kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false],
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(parameters as CFDictionary, &error) else {
      throw securityFailure("key-create-failed", error)
    }
    identity.keyPublicSHA256 = try publicHash(key)
    // A collision never obtains a cleanup claim, and is never pre-cleaned.
    try requireNotFound(queryStatus(keyTagQuery(identity)), "key-tag-already-present")
    try requireNotFound(
      queryStatus(certificateLabelQuery(identity)), "certificate-label-already-present")
    identity.keyCreationState = .armed
    try save(identity, role: role, manifest: &manifest, files: files)
    let keyAttributes: [CFString: Any] = [
      kSecClass: kSecClassKey,
      kSecValueRef: key,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits: 256,
      kSecAttrApplicationTag: identity.keyTag,
      kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecAttrSynchronizable: false,
      kSecReturnPersistentRef: true,
    ]
    var keyResult: CFTypeRef?
    let keyStatus = SecItemAdd(keyAttributes as CFDictionary, &keyResult)
    if keyStatus != errSecSuccess {
      identity.keyCreationState = .unclaimed
      do {
        try save(identity, role: role, manifest: &manifest, files: files)
      } catch {
        throw ResearchFailure("key-add-claim-save-failed", osStatus: Int(keyStatus))
      }
      throw ResearchFailure("key-add-failed", osStatus: Int(keyStatus))
    }
    if fault == .afterKeyAdd { throw ResearchFailure("injected-after-key-add") }
    guard let keyReference = keyResult as? Data, !keyReference.isEmpty else {
      throw ResearchFailure("key-reference-invalid")
    }
    identity.keyPersistentRef = keyReference
    identity.keyCreationState = .created
    try save(identity, role: role, manifest: &manifest, files: files)

    let certificate = try issueCertificate(key: key, id: identity.id)
    identity.certificateSHA256 = digest(SecCertificateCopyData(certificate) as Data)
    // Recheck immediately before arming. An armed claim alone is insufficient:
    // recovery must also validate this known, newly issued certificate's DER hash.
    try requireNotFound(
      queryStatus(certificateLabelQuery(identity)), "certificate-label-already-present")
    identity.certificateCreationState = .armed
    try save(identity, role: role, manifest: &manifest, files: files)
    let attributes: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecValueRef: certificate,
      kSecAttrLabel: identity.certificateLabel,
      kSecAttrSynchronizable: false,
      kSecReturnPersistentRef: true,
    ]
    var result: CFTypeRef?
    let status = SecItemAdd(attributes as CFDictionary, &result)
    if status != errSecSuccess {
      identity.certificateCreationState = .unclaimed
      do {
        try save(identity, role: role, manifest: &manifest, files: files)
      } catch {
        throw ResearchFailure("certificate-add-claim-save-failed", osStatus: Int(status))
      }
      throw ResearchFailure("certificate-add-failed", osStatus: Int(status))
    }
    if fault == .afterCertificateAdd { throw ResearchFailure("injected-after-certificate-add") }
    guard let reference = result as? Data, !reference.isEmpty else {
      throw ResearchFailure("certificate-reference-invalid")
    }
    identity.certificatePersistentRef = reference
    identity.certificateCreationState = .created
    try save(identity, role: role, manifest: &manifest, files: files)
  }

  private static func issueCertificate(key: SecKey, id: String) throws -> SecCertificate {
    do {
      let csrDER = try MunieCSR.makeDER(privateKey: key, commonName: "Munie \(id)")
      let csr = try CertificateSigningRequest(derEncoded: Array(csrDER))
      guard csr.publicKey.isValidSignature(csr.signature, for: csr),
        csr.publicKey == (try Certificate.PrivateKey(key)).publicKey
      else { throw ResearchFailure("csr-verification-failed") }
      let issuerKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
      let now = Date()
      let leaf = try Certificate(
        version: .v3,
        serialNumber: .init(),
        publicKey: csr.publicKey,
        notValidBefore: now.addingTimeInterval(-60),
        notValidAfter: now.addingTimeInterval(3_600),
        issuer: DistinguishedName { CommonName("Munie Synthetic Issuer \(id)") },
        subject: csr.subject,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: Certificate.Extensions {
          Critical(BasicConstraints.notCertificateAuthority)
          Critical(KeyUsage(digitalSignature: true))
          try ExtendedKeyUsage([.clientAuth])
        },
        issuerPrivateKey: issuerKey)
      guard issuerKey.publicKey.isValidSignature(leaf.signature, for: leaf) else {
        throw ResearchFailure("certificate-signature-invalid")
      }
      var serializer = DER.Serializer()
      try serializer.serialize(leaf)
      guard
        let certificate = SecCertificateCreateWithData(
          nil, Data(serializer.serializedBytes) as CFData)
      else { throw ResearchFailure("certificate-encoding-invalid") }
      return certificate
    } catch let failure as ResearchFailure {
      throw failure
    } catch {
      throw ResearchFailure("certificate-issuance-failed")
    }
  }

  private static func verify(_ owned: OwnedIdentity, nonce: String) throws {
    guard let expectedKeyHash = owned.keyPublicSHA256,
      let expectedCertificateHash = owned.certificateSHA256
    else {
      throw ResearchFailure("manifest-incomplete")
    }
    // A successful exact persistent-ref query proves a stored item was read. The
    // add parameters and returned accessibility/sync attributes are checked too.
    let key = try loadKey(try requiredReference(owned.keyPersistentRef), owned: owned)
    let certificate = try loadCertificate(
      try requiredReference(owned.certificatePersistentRef), owned: owned)
    guard try publicHash(key) == expectedKeyHash,
      digest(SecCertificateCopyData(certificate) as Data) == expectedCertificateHash
    else { throw ResearchFailure("stored-item-mismatch") }
    guard let identity = SecIdentityCreate(nil, certificate, key) else {
      throw ResearchFailure("identity-create-failed")
    }
    var identityCertificate: SecCertificate?
    try requireSuccess(
      SecIdentityCopyCertificate(identity, &identityCertificate), "identity-certificate-failed")
    guard let identityCertificate,
      (SecCertificateCopyData(identityCertificate) as Data)
        == (SecCertificateCopyData(certificate) as Data)
    else { throw ResearchFailure("identity-leaf-mismatch") }
    var identityKey: SecKey?
    try requireSuccess(
      SecIdentityCopyPrivateKey(identity, &identityKey), "identity-private-key-failed")
    guard let identityKey, let publicKey = SecCertificateCopyKey(identityCertificate),
      try publicHash(identityKey) == expectedKeyHash
    else { throw ResearchFailure("identity-public-key-mismatch") }
    let message = Data("Munie identity possession \(owned.id) \(nonce)".utf8)
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        identityKey, .ecdsaSignatureMessageX962SHA256, message as CFData, &error)
    else { throw securityFailure("identity-signature-failed", error) }
    guard
      SecKeyVerifySignature(
        publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature, &error)
    else { throw securityFailure("identity-possession-failed", error) }
  }

  private static func rejectMismatchedIdentity(_ owned: OwnedIdentity) throws {
    let certificate = try loadCertificate(
      try requiredReference(owned.certificatePersistentRef), owned: owned)
    let parameters: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits: 256,
      kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false],
    ]
    var error: Unmanaged<CFError>?
    guard let unrelatedKey = SecKeyCreateRandomKey(parameters as CFDictionary, &error) else {
      throw securityFailure("mismatch-key-create-failed", error)
    }
    guard SecIdentityCreate(nil, certificate, unrelatedKey) == nil else {
      throw ResearchFailure("mismatched-identity-accepted")
    }
  }

  private static func confirmDeleted(_ owned: OwnedIdentity, report: inout ResearchReport) throws {
    let keyStatus = queryStatus(
      referenceQuery(try requiredReference(owned.keyPersistentRef), itemClass: kSecClassKey))
    let certificateStatus = queryStatus(
      referenceQuery(
        try requiredReference(owned.certificatePersistentRef), itemClass: kSecClassCertificate))
    report.checks["keyLookupStatus"] = .status(Int(keyStatus))
    report.checks["certificateLookupStatus"] = .status(Int(certificateStatus))
    try requireNotFound(keyStatus, "deleted-key-found")
    try requireNotFound(certificateStatus, "deleted-certificate-found")
  }

  private static func cleanup(_ owned: OwnedIdentity) throws {
    var firstFailure: ResearchFailure?
    // Try both resources even when one fails; preserve a concrete failure status.
    for itemClass in [kSecClassCertificate, kSecClassKey] {
      do {
        let isKey = itemClass == kSecClassKey
        // Unclaimed includes preflight collisions and explicit failed adds. Do not
        // query or delete their tags/labels, even if a preexisting item is present.
        guard try owned.cleanupExpectedHash(for: isKey ? .key : .certificate) != nil else {
          continue
        }
        let savedReference = isKey ? owned.keyPersistentRef : owned.certificatePersistentRef
        let ownershipQuery = isKey ? keyTagQuery(owned) : certificateLabelQuery(owned)
        let reference: Data?
        if let savedReference {
          // Validate an extant referenced item against its own UUID/hash first.
          let status = queryStatus(referenceQuery(savedReference, itemClass: itemClass))
          if status == errSecSuccess {
            if isKey {
              _ = try loadKey(savedReference, owned: owned)
            } else {
              _ = try loadCertificate(savedReference, owned: owned)
            }
          } else {
            try requireNotFound(status, "cleanup-reference-query-failed")
          }
          reference = savedReference
        } else {
          let status = queryStatus(ownershipQuery)
          if status == errSecItemNotFound {
            reference = nil
          } else {
            try requireSuccess(status, "cleanup-own-query-failed")
            let recovered = try findPersistentReference(ownershipQuery)
            if isKey {
              _ = try loadKey(recovered, owned: owned)
            } else {
              _ = try loadCertificate(recovered, owned: owned)
            }
            reference = recovered
          }
        }
        if let reference {
          let status = deleteReference(reference, itemClass: itemClass)
          guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ResearchFailure("cleanup-delete-failed", osStatus: Int(status))
          }
          try requireNotFound(
            queryStatus(referenceQuery(reference, itemClass: itemClass)),
            "cleanup-reference-still-present")
        }
        try requireNotFound(queryStatus(ownershipQuery), "cleanup-own-item-still-present")
      } catch let failure as ResearchFailure {
        if firstFailure == nil { firstFailure = failure }
      } catch {
        if firstFailure == nil { firstFailure = ResearchFailure("cleanup-item-failed") }
      }
    }
    if let firstFailure { throw firstFailure }
  }

  private static func keyTagQuery(_ owned: OwnedIdentity) -> [CFString: Any] {
    [
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: owned.keyTag,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrSynchronizable: false,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
  }

  private static func certificateLabelQuery(_ owned: OwnedIdentity) -> [CFString: Any] {
    [
      kSecClass: kSecClassCertificate,
      kSecAttrLabel: owned.certificateLabel,
      kSecAttrSynchronizable: false,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
  }

  private static func referenceQuery(_ reference: Data, itemClass: CFString) -> [CFString: Any] {
    [kSecClass: itemClass, kSecValuePersistentRef: reference, kSecMatchLimit: kSecMatchLimitOne]
  }

  private static func queryStatus(_ query: [CFString: Any]) -> OSStatus {
    SecItemCopyMatching(query as CFDictionary, nil)
  }

  private static func findPersistentReference(_ query: [CFString: Any]) throws -> Data {
    var query = query
    query[kSecReturnPersistentRef] = true
    var result: CFTypeRef?
    try requireSuccess(
      SecItemCopyMatching(query as CFDictionary, &result), "persistent-reference-query-failed")
    guard let reference = result as? Data, !reference.isEmpty else {
      throw ResearchFailure("persistent-reference-invalid")
    }
    return reference
  }

  private static func loadKey(_ reference: Data, owned: OwnedIdentity) throws -> SecKey {
    guard let expectedHash = owned.keyPublicSHA256 else {
      throw ResearchFailure("manifest-ownership-hash-missing")
    }
    var query = referenceQuery(reference, itemClass: kSecClassKey)
    query[kSecReturnRef] = true
    query[kSecReturnAttributes] = true
    var result: CFTypeRef?
    try requireSuccess(
      SecItemCopyMatching(query as CFDictionary, &result), "key-reference-query-failed")
    guard let attributes = result as? [String: Any],
      let value = attributes[kSecValueRef as String],
      CFGetTypeID(value as CFTypeRef) == SecKeyGetTypeID(),
      attributes[kSecAttrApplicationTag as String] as? Data == owned.keyTag,
      attributes[kSecAttrAccessible as String] as? String
        == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
      (attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false
    else { throw ResearchFailure("key-ownership-mismatch") }
    let key = value as! SecKey
    guard try publicHash(key) == expectedHash else {
      throw ResearchFailure("key-public-hash-mismatch")
    }
    return key
  }

  private static func loadCertificate(_ reference: Data, owned: OwnedIdentity) throws
    -> SecCertificate
  {
    var query = referenceQuery(reference, itemClass: kSecClassCertificate)
    query[kSecReturnRef] = true
    query[kSecReturnAttributes] = true
    var result: CFTypeRef?
    try requireSuccess(
      SecItemCopyMatching(query as CFDictionary, &result), "certificate-reference-query-failed")
    guard let attributes = result as? [String: Any],
      let value = attributes[kSecValueRef as String],
      CFGetTypeID(value as CFTypeRef) == SecCertificateGetTypeID(),
      attributes[kSecAttrLabel as String] as? String == owned.certificateLabel,
      let expectedHash = owned.certificateSHA256
    else { throw ResearchFailure("certificate-ownership-mismatch") }
    let certificate = value as! SecCertificate
    guard digest(SecCertificateCopyData(certificate) as Data) == expectedHash else {
      throw ResearchFailure("certificate-hash-mismatch")
    }
    return certificate
  }

  private static func deleteReference(_ reference: Data, itemClass: CFString) -> OSStatus {
    SecItemDelete([kSecClass: itemClass, kSecValuePersistentRef: reference] as CFDictionary)
  }

  private static func publicHash(_ key: SecKey) throws -> String {
    var error: Unmanaged<CFError>?
    guard let publicKey = SecKeyCopyPublicKey(key),
      let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
    else { throw securityFailure("public-key-copy-failed", error) }
    return digest(data)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func requiredReference(_ reference: Data?) throws -> Data {
    guard let reference, !reference.isEmpty else {
      throw ResearchFailure("manifest-reference-missing")
    }
    return reference
  }

  private static func requireSuccess(_ status: OSStatus, _ code: String) throws {
    guard status == errSecSuccess else { throw ResearchFailure(code, osStatus: Int(status)) }
  }

  private static func requireNotFound(_ status: OSStatus, _ code: String) throws {
    guard status == errSecItemNotFound else { throw ResearchFailure(code, osStatus: Int(status)) }
  }

  private static func securityFailure(_ code: String, _ error: Unmanaged<CFError>?)
    -> ResearchFailure
  {
    ResearchFailure(code, osStatus: error.map { CFErrorGetCode($0.takeRetainedValue()) })
  }
}
