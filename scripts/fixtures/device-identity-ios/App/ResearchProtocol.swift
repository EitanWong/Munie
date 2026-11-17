import Foundation

enum ResearchPhase: String, Codable, Sendable {
  case create
  case reopen
  case delete
  case confirmDeleted = "confirm-deleted"
  case cleanup
}

enum ResearchFault: String, Sendable {
  case afterKeyAdd = "after-key-add"
  case afterCertificateAdd = "after-certificate-add"
}

struct ResearchInput: Sendable {
  let runID: String
  let phase: ResearchPhase
  let nonce: String
  let fault: ResearchFault?

  static func parse(_ arguments: [String]) throws -> Self {
    let values = Array(arguments.dropFirst())
    guard values.count == 6 || values.count == 8 else {
      throw ResearchFailure("invalid-arguments")
    }
    var fields: [String: String] = [:]
    for offset in stride(from: 0, to: values.count, by: 2) {
      let name = values[offset]
      guard ["--run-id", "--phase", "--nonce", "--fault"].contains(name), fields[name] == nil else {
        throw ResearchFailure("invalid-arguments")
      }
      fields[name] = values[offset + 1]
    }
    guard let rawRunID = fields["--run-id"], let runID = UUID(uuidString: rawRunID),
      let rawPhase = fields["--phase"], let phase = ResearchPhase(rawValue: rawPhase),
      let rawNonce = fields["--nonce"], let nonce = UUID(uuidString: rawNonce)
    else { throw ResearchFailure("invalid-arguments") }
    let fault: ResearchFault?
    if let rawFault = fields["--fault"] {
      guard phase == .create, let parsedFault = ResearchFault(rawValue: rawFault) else {
        throw ResearchFailure("invalid-arguments")
      }
      fault = parsedFault
    } else {
      fault = nil
    }
    return Self(runID: runID.uuidString, phase: phase, nonce: nonce.uuidString, fault: fault)
  }
}

struct ResearchFailure: Error, Sendable {
  let code: String
  let osStatus: Int?

  init(_ code: String, osStatus: Int? = nil) {
    self.code = code
    self.osStatus = osStatus
  }
}

enum ResearchCheck: Encodable, Sendable {
  case flag(Bool)
  case status(Int)

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .flag(let value): try container.encode(value)
    case .status(let value): try container.encode(value)
    }
  }
}

struct ResearchReport: Encodable, Sendable {
  let schemaVersion = 1
  let runID: String
  let phase: String
  let nonce: String
  let launchID = UUID().uuidString
  let processID = Int(ProcessInfo.processInfo.processIdentifier)
  var passed = false
  var checks: [String: ResearchCheck] = [:]
  var failure: String?
  var osStatus: Int?
}

enum ItemCreationState: String, Codable {
  case unclaimed
  case armed
  case created
}

enum IdentityItem {
  case key
  case certificate
}

struct OwnedIdentity: Codable {
  let id: String
  let keyTag: Data
  let certificateLabel: String
  var keyPersistentRef: Data?
  var certificatePersistentRef: Data?
  var keyPublicSHA256: String?
  var certificateSHA256: String?
  var keyCreationState = ItemCreationState.unclaimed
  var certificateCreationState = ItemCreationState.unclaimed

  init(id: String) {
    self.id = id
    keyTag = Data("app.munie.research.identity.\(id).private-key".utf8)
    certificateLabel = "app.munie.research.identity.\(id).certificate"
  }

  func validate() throws {
    guard UUID(uuidString: id)?.uuidString == id else {
      throw ResearchFailure("manifest-invalid")
    }
    let expected = OwnedIdentity(id: id)
    guard keyTag == expected.keyTag, certificateLabel == expected.certificateLabel else {
      throw ResearchFailure("manifest-invalid")
    }
    for reference in [keyPersistentRef, certificatePersistentRef].compactMap({ $0 }) {
      guard !reference.isEmpty, reference.count <= 2_048 else {
        throw ResearchFailure("manifest-invalid")
      }
    }
    for hash in [keyPublicSHA256, certificateSHA256].compactMap({ $0 }) {
      guard hash.count == 64,
        hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw ResearchFailure("manifest-invalid") }
    }
    for item in [IdentityItem.key, .certificate] {
      _ = try cleanupExpectedHash(for: item)
      let state = item == .key ? keyCreationState : certificateCreationState
      let reference = item == .key ? keyPersistentRef : certificatePersistentRef
      guard (state == .created) == (reference != nil) else {
        throw ResearchFailure("manifest-invalid-ownership")
      }
    }
  }

  func cleanupExpectedHash(for item: IdentityItem) throws -> String? {
    let state = item == .key ? keyCreationState : certificateCreationState
    guard state != .unclaimed else { return nil }
    guard let hash = item == .key ? keyPublicSHA256 : certificateSHA256 else {
      throw ResearchFailure("manifest-ownership-hash-missing")
    }
    return hash
  }
}

struct ResearchManifest: Codable {
  let schemaVersion: Int
  let runID: String
  var target: OwnedIdentity
  var control: OwnedIdentity

  init(runID: String) {
    schemaVersion = 1
    self.runID = runID
    target = OwnedIdentity(id: runID)
    control = OwnedIdentity(id: UUID().uuidString)
  }

  func validate(runID expectedRunID: String) throws {
    guard schemaVersion == 1, runID == expectedRunID, target.id == runID, control.id != runID else {
      throw ResearchFailure("manifest-run-mismatch")
    }
    try target.validate()
    try control.validate()
  }
}

struct ResearchFiles {
  let directory: URL
  var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
  var reportURL: URL { directory.appendingPathComponent("report.json") }

  init() throws {
    guard
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { throw ResearchFailure("container-path-unavailable") }
    directory = support.appendingPathComponent("MunieIdentityResearch", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [
          .posixPermissions: 0o700,
          .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
    } catch {
      throw ResearchFailure("container-directory-failed")
    }
  }

  func saveManifest(_ manifest: ResearchManifest) throws {
    do {
      let data = try JSONEncoder().encode(manifest)
      guard data.count <= 16_384 else { throw ResearchFailure("manifest-overflow") }
      try data.write(
        to: manifestURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch let failure as ResearchFailure {
      throw failure
    } catch {
      throw ResearchFailure("manifest-write-failed")
    }
  }

  func loadManifest(runID: String) throws -> ResearchManifest {
    do {
      let data = try Data(contentsOf: manifestURL)
      guard data.count <= 16_384 else { throw ResearchFailure("manifest-overflow") }
      let manifest = try JSONDecoder().decode(ResearchManifest.self, from: data)
      try manifest.validate(runID: runID)
      return manifest
    } catch let failure as ResearchFailure {
      throw failure
    } catch {
      throw ResearchFailure("manifest-read-failed")
    }
  }

  func saveReport(_ report: ResearchReport) throws {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(report)
      guard data.count <= 16_384 else { throw ResearchFailure("report-overflow") }
      try data.write(
        to: reportURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch let failure as ResearchFailure {
      throw failure
    } catch {
      throw ResearchFailure("report-write-failed")
    }
  }
}
