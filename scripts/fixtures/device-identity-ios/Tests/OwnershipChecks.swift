import Foundation

struct CheckFailure: Error { let name: String }

@main
struct OwnershipChecks {
  static func require(_ value: Bool, _ name: String) throws {
    guard value else { throw CheckFailure(name: name) }
    print("PASS \(name)")
  }

  static func requireFailure(_ code: String, _ name: String, _ body: () throws -> Void) throws {
    do {
      try body()
      throw CheckFailure(name: name)
    } catch let failure as ResearchFailure {
      try require(failure.code == code, name)
    }
  }

  static func main() throws {
    let runID = "6B7DAF3B-3C13-4321-89AA-2E4F7FD607B8"
    let hash = String(repeating: "a", count: 64)
    var identity = OwnedIdentity(id: runID)
    try require(
      try identity.cleanupExpectedHash(for: .key) == nil, "unclaimed-key-collision-skipped")
    try require(
      try identity.cleanupExpectedHash(for: .certificate) == nil,
      "unclaimed-certificate-collision-skipped")
    identity.keyPublicSHA256 = hash
    try require(
      try identity.cleanupExpectedHash(for: .key) == nil, "failed-add-unclaimed-with-hash-skipped")
    identity.keyPublicSHA256 = nil
    identity.keyCreationState = .armed
    try requireFailure("manifest-ownership-hash-missing", "armed-key-needs-hash") {
      _ = try identity.cleanupExpectedHash(for: .key)
    }
    identity.keyCreationState = .unclaimed
    identity.certificateCreationState = .armed
    try requireFailure("manifest-ownership-hash-missing", "armed-certificate-needs-hash") {
      _ = try identity.cleanupExpectedHash(for: .certificate)
    }
    identity.certificateSHA256 = hash
    try require(
      try identity.cleanupExpectedHash(for: .certificate) == hash,
      "armed-certificate-before-ref-recoverable")
    try identity.validate()
    identity.keyCreationState = .armed
    identity.keyPublicSHA256 = hash
    try require(
      try identity.cleanupExpectedHash(for: .key) == hash, "armed-key-before-ref-recoverable")
    try identity.validate()
    identity.keyCreationState = .created
    try requireFailure("manifest-invalid-ownership", "created-key-needs-ref") {
      try identity.validate()
    }
    identity.keyPersistentRef = Data([1])
    try identity.validate()
    try require(true, "created-key-with-hash-and-ref-accepted")
    identity.keyCreationState = .unclaimed
    try requireFailure("manifest-invalid-ownership", "unclaimed-key-cannot-hide-ref") {
      try identity.validate()
    }
    let regular = ["research", "--run-id", runID, "--phase", "create", "--nonce", runID]
    try require(try ResearchInput.parse(regular).fault == nil, "regular-six-arguments-compatible")
    for fault in ["after-key-add", "after-certificate-add"] {
      let input = try ResearchInput.parse(regular + ["--fault", fault])
      try require(input.fault?.rawValue == fault, "accepted-\(fault)-injection")
    }
    let reopen = ["research", "--run-id", runID, "--phase", "reopen", "--nonce", runID]
    try requireFailure("invalid-arguments", "fault-rejected-outside-create") {
      _ = try ResearchInput.parse(reopen + ["--fault", "after-key-add"])
    }
    try requireFailure("invalid-arguments", "unknown-fault-rejected") {
      _ = try ResearchInput.parse(regular + ["--fault", "unknown"])
    }
    print("ownershipChecks=15 passed=true securityAPIsInvoked=false")
  }
}
