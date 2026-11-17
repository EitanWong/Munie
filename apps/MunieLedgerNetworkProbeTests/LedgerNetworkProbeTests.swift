import Darwin
import Foundation
import MunieExecutionHost
import SQLite3
import Testing

@testable import MunieLedgerNetworkProbe

struct LedgerNetworkProbeTests {
  @Test func acceptanceReadsAndDuplicateClaimsUseTheActualLedger() async throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let bridge = try await fixture.open()
    let accepted = try await bridge.respond(to: fixture.frame())
    #expect(accepted == fixture.snapshot(.accepted))
    #expect(try await bridge.respond(to: fixture.frame()) == accepted)
    #expect(try await bridge.respond(to: fixture.frame(operation: "snapshot")) == accepted)
    let first = try await bridge.respond(to: fixture.frame(operation: "claim"))
    #expect(first.object?["state"] == .string("ledger-claim"))
    #expect(first.object?["send"] == .bool(true))
    #expect(first.object?["phase"] == .string("dispatching"))
    let repeated = try await bridge.respond(to: fixture.frame(operation: "claim"))
    #expect(repeated.object?["send"] == .bool(false))
    #expect(repeated.object?["phase"] == .string("dispatching"))
    #expect(try await bridge.respond(to: fixture.frame()) == fixture.snapshot(.dispatching))
    #expect(try fixture.query("SELECT phase FROM requests") == [["dispatching"]])
    #expect(try fixture.query("SELECT count(*) FROM threads") == [["0"]])
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("effects.txt").path))
  }

  @Test func fingerprintIdentityPreventsCrossDeviceReadReuseAndClaim() async throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let bridge = try await fixture.open()
    #expect(try await bridge.respond(to: fixture.frame()) == fixture.snapshot(.accepted))
    for operation in ["accept", "snapshot", "claim"] {
      #expect(
        try await bridge.respond(
          to: fixture.frame(operation: operation, fingerprint: fixture.otherFingerprint))
          == error("unauthorized"))
      #expect(
        try await bridge.respond(
          to: fixture.frame(operation: operation, fingerprint: String(repeating: "f", count: 64)))
          == error("unauthorized"))
    }
    #expect(try fixture.query("SELECT count(*) FROM requests") == [["1"]])
  }

  @Test func persistedGrantsDenyAnotherProjectAndExactPayloadChangesConflict() async throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let bridge = try await fixture.open()
    #expect(
      try await bridge.respond(to: fixture.frame(project: fixture.otherProjectID))
        == error("unauthorized"))
    #expect(try await bridge.respond(to: fixture.frame()) == fixture.snapshot(.accepted))
    for text in ["é\n", " é", "e\u{301}"] {
      for operation in ["accept", "claim"] {
        #expect(
          try await bridge.respond(to: fixture.frame(operation: operation, text: text))
            == error("request-conflict"))
      }
    }
    #expect(try await bridge.respond(to: fixture.frame(text: " \n\t")) == error("invalid-request"))
    #expect(try fixture.query("SELECT phase FROM requests") == [["accepted"]])
  }

  @Test func revocationDeniesExistingRequestsAndSurvivesResumeWithoutReseeding() async throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    try await fixture.withReleasedBridge { bridge async throws in
      #expect(try await bridge.respond(to: fixture.frame()) == fixture.snapshot(.accepted))
      #expect(
        try await bridge.respond(to: fixture.revoke()) == .object(["event": .string("revoked")]))
      for operation in ["accept", "snapshot", "claim"] {
        #expect(
          try await bridge.respond(to: fixture.frame(operation: operation)) == error("unauthorized")
        )
      }
    }
    let reopened = try await fixture.open(initialize: false)
    for operation in ["accept", "snapshot", "claim"] {
      #expect(
        try await reopened.respond(to: fixture.frame(operation: operation)) == error("unauthorized")
      )
    }
    #expect(
      try await reopened.respond(to: fixture.frame(requestID: UUID())) == error("unauthorized"))
    #expect(
      try fixture.query("SELECT enabled FROM devices WHERE id='\(fixture.deviceID.uuidString)'")
        == [["0"]])
    #expect(try fixture.query("SELECT phase FROM requests") == [["accepted"]])
  }

  @Test func restartReconcilesClaimAndNeverIssuesAnotherSend() async throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    try await fixture.withReleasedBridge { bridge in
      _ = try await bridge.respond(to: fixture.frame())
      let response = try await bridge.respond(to: fixture.frame(operation: "claim"))
      #expect(response.object?["send"] == .bool(true))
    }
    let reopened = try await fixture.open(initialize: false)
    #expect(try await reopened.respond(to: fixture.frame()) == fixture.snapshot(.reconciling))
    let claim = try await reopened.respond(to: fixture.frame(operation: "claim"))
    #expect(claim.object?["send"] == .bool(false))
    #expect(claim.object?["phase"] == .string("reconciling"))
    #expect(try fixture.query("SELECT phase FROM requests") == [["reconciling"]])
  }

  @Test func unknownRequestsKeepTheUnderlyingLedgerLookupBoundary() async throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let bridge = try await fixture.open()
    for operation in ["snapshot", "claim"] {
      #expect(
        try await bridge.respond(to: fixture.frame(operation: operation))
          == error("unknown-request"))
    }
    _ = try await bridge.respond(to: fixture.revoke())
    // HostSubmissionLedger.snapshot looks up the ID before checking its existing owner/grant.
    #expect(
      try await bridge.respond(to: fixture.frame(operation: "snapshot")) == error("unknown-request")
    )
    #expect(
      try await bridge.respond(to: fixture.frame(operation: "claim")) == error("unauthorized"))
    #expect(try fixture.query("SELECT count(*) FROM requests") == [["0"]])
  }

  @Test func initializeRefusesExistingStateAndResumeDoesNotCreateMissingState() async throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    await #expect(throws: (any Error).self) { try await fixture.open(initialize: false) }
    #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
    try await fixture.withReleasedBridge { bridge in
      _ = try await bridge.respond(to: fixture.frame())
    }
    let pristine = try Data(contentsOf: fixture.state.appendingPathComponent("submissions.sqlite3"))
    await #expect(throws: (any Error).self) { try await fixture.open(initialize: true) }
    #expect(
      try Data(contentsOf: fixture.state.appendingPathComponent("submissions.sqlite3")) == pristine)
  }

  @Test func storageOrProjectFailuresPropagateInsteadOfReturningFakeSuccess() async throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let bridge = try await fixture.open()
    let original = fixture.project(fixture.projectID)
    let saved = original.appendingPathExtension("saved")
    try FileManager.default.moveItem(at: original, to: saved)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
    await #expect(throws: SubmissionError.projectChanged) {
      try await bridge.respond(to: fixture.frame())
    }
    #expect(try fixture.query("SELECT count(*) FROM requests") == [["0"]])
  }

  @Test func resumeRejectsANonemptyUninitializedSQLiteFileWithoutCreatingLedgerTables() async throws
  {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let databaseURL = fixture.state.appendingPathComponent("submissions.sqlite3")
    let owner = fixture.state.appendingPathComponent(".owner")
    #expect(
      FileManager.default.createFile(
        atPath: owner.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    #expect(
      sqlite3_exec(database, "CREATE TABLE unrelated(value TEXT)", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_close(database) == SQLITE_OK)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    let baseline = try Data(contentsOf: databaseURL)
    await #expect(throws: (any Error).self) { try await fixture.open(initialize: false) }
    #expect(try Data(contentsOf: databaseURL) == baseline)
    #expect(try fixture.query("PRAGMA user_version") == [["0"]])
    #expect(
      try fixture.query("SELECT name FROM sqlite_master WHERE type='table'") == [["unrelated"]])
  }

  @Test func forgedFieldsAndMalformedStrictJSONCannotChooseAnIdentityOrMutateStorage() async throws
  {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let bridge = try await fixture.open()
    var forged = try #require(CodexJSON.decode(fixture.frame()).object)
    forged["deviceID"] = .string(fixture.otherDeviceID.uuidString)
    let validText = String(decoding: try fixture.frame(), as: UTF8.self)
    let malformed = [
      try CodexJSON.object(forged).encoded(), Data("[]".utf8), Data([0xFF]),
      Data("{\"operation\":\"snapshot\",\"operation\":\"accept\"}".utf8),
      Data("{\"operation\":\"snapshot\",\"\\u006fperation\":\"accept\"}".utf8),
      Data("{\"operation\":\"accept\"}".utf8), Data("{\"operation\":false}".utf8),
      Data(validText.replacingOccurrences(of: "\"text\":\"é\"", with: "\"text\":true").utf8),
      Data(validText.replacingOccurrences(of: "\"text\":\"é\"", with: "\"text\":1.0").utf8),
      Data(
        validText.replacingOccurrences(
          of: fixture.fingerprint, with: fixture.fingerprint.uppercased()
        ).utf8),
      Data(
        validText.replacingOccurrences(
          of: fixture.requestID.uuidString, with: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        ).utf8),
      Data(repeating: 32, count: 4097),
    ]
    for frame in malformed {
      #expect(try await bridge.respond(to: frame) == error("invalid-request"))
    }
    #expect(try fixture.query("SELECT count(*) FROM requests") == [["0"]])
    #expect(try await bridge.respond(to: fixture.frame()) == fixture.snapshot(.accepted))
  }

  @Test func configurationRejectsDuplicateUnknownAliasAndUngrantableValues() throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let good = try fixture.configurationValue()
    var unknown = try #require(good.object)
    unknown["token"] = .string("synthetic-private")
    var badInitialize = try #require(good.object)
    badInitialize["initialize"] = .integer(1)
    var duplicateProject = try #require(good.object)
    duplicateProject["projects"] = .array([
      .string(fixture.projectID.uuidString), .string(fixture.projectID.uuidString),
    ])
    var duplicateDevice = try #require(good.object)
    let firstDevice = try #require(duplicateDevice["devices"]?.array?.first)
    duplicateDevice["devices"] = .array([firstDevice, firstDevice])
    var duplicateDeviceID = try #require(good.object)
    var aliasDevice = try #require(firstDevice.object)
    aliasDevice["fingerprint"] = .string(String(repeating: "c", count: 64))
    duplicateDeviceID["devices"] = .array([firstDevice, .object(aliasDevice)])
    var ungranted = try #require(good.object)
    var ungrantedDevice = try #require(firstDevice.object)
    ungrantedDevice["projectIDs"] = .array([.string(UUID().uuidString)])
    ungranted["devices"] = .array([.object(ungrantedDevice)])
    var lowercase = try #require(good.object)
    lowercase["hostID"] = .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    for value in [
      unknown, badInitialize, duplicateProject, duplicateDevice, duplicateDeviceID, ungranted,
      lowercase,
    ] {
      #expect(throws: (any Error).self) {
        try LedgerNetworkConfiguration.decode(CodexJSON.object(value).encoded())
      }
    }
    #expect(throws: (any Error).self) {
      try LedgerNetworkConfiguration.decode(Data("{\"initialize\":true,\"initialize\":false}".utf8))
    }
  }

  @Test func configurationRequiresPrivateCanonicalDirectoriesAndFiles() async throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let path = fixture.root.appendingPathComponent("configuration.json")
    try fixture.configurationValue().encoded().write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    _ = try LedgerNetworkConfiguration.load(path: path.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    #expect(throws: (any Error).self) { try LedgerNetworkConfiguration.load(path: path.path) }
    #expect(throws: (any Error).self) { try LedgerNetworkConfiguration.load(path: "relative.json") }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fixture.project(fixture.projectID).path)
    await #expect(throws: (any Error).self) { try await fixture.open() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: fixture.project(fixture.projectID).path)
    try FileManager.default.moveItem(
      at: fixture.project(fixture.projectID), to: fixture.root.appendingPathComponent("moved"))
    try FileManager.default.createSymbolicLink(
      at: fixture.project(fixture.projectID),
      withDestinationURL: fixture.root.appendingPathComponent("moved"))
    await #expect(throws: (any Error).self) { try await fixture.open() }
    #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
  }

  @Test func framesHaveABoundedResynchronizableLineBoundaryAndBoundedOutput() throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("wire")
    try (Data(repeating: 32, count: 4096) + Data("\n{}\n".utf8)).write(to: file)
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    #expect(try LedgerNetworkWire.readLine(from: input)?.count == 4096)
    #expect(try LedgerNetworkWire.readLine(from: input) == Data("{}".utf8))
    #expect(try LedgerNetworkWire.readLine(from: input) == nil)
    for data in [Data(repeating: 32, count: 4097) + Data([10]), Data("{}".utf8)] {
      try data.write(to: file)
      let oversized = try FileHandle(forReadingFrom: file)
      defer { try? oversized.close() }
      #expect(throws: LedgerNetworkProbeFailure.self) {
        try LedgerNetworkWire.readLine(from: oversized)
      }
    }
    let output = try FileHandle(forWritingTo: file)
    defer { try? output.close() }
    try output.truncate(atOffset: 0)
    try LedgerNetworkWire.emit(fixture.snapshot(.accepted), to: output)
    #expect(try Data(contentsOf: file).count <= 2048)
    #expect(throws: (any Error).self) {
      try LedgerNetworkWire.emit(.string(String(repeating: "x", count: 2048)), to: output)
    }
  }

  @Test func ledgerStoresDigestAndDeviceIdentityWithoutPlaintextOrFingerprint() async throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let bridge = try await fixture.open()
    let text = "MUNIE_SYNTHETIC_PRIVATE_TEXT_\(UUID().uuidString)"
    _ = try await bridge.respond(to: fixture.frame(text: text))
    let identity = try #require(fixture.query("SELECT identity FROM requests").first?.first)
    let fields = try #require(CodexJSON.decode(Data(identity.utf8)).object)
    #expect(fields["deviceID"] == .string(fixture.deviceID.uuidString))
    #expect(fields["hostID"] == .string(fixture.hostID.uuidString))
    #expect(fields["payloadDigest"]?.string?.utf8.count == 64)
    let bytes = try Data(contentsOf: fixture.state.appendingPathComponent("submissions.sqlite3"))
    #expect(bytes.range(of: Data(text.utf8)) == nil)
    #expect(bytes.range(of: Data(fixture.fingerprint.utf8)) == nil)
  }
}

private func error(_ code: String) -> CodexJSON {
  .object(["event": .string("result"), "error": .string(code)])
}

private struct BridgeFixture: Sendable {
  let root: URL
  let hostID = UUID()
  let projectID = UUID()
  let otherProjectID = UUID()
  let deviceID = UUID()
  let otherDeviceID = UUID()
  let requestID = UUID()
  let fingerprint = String(repeating: "a", count: 64)
  let otherFingerprint = String(repeating: "b", count: 64)
  var state: URL { root.appendingPathComponent("state", isDirectory: true) }

  init() throws {
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw SubmissionError.invalidStorage
    }
    defer { free(resolved) }
    let temporary = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    root = temporary.appendingPathComponent(
      "munie-ledger-network-\(UUID().uuidString)", isDirectory: true)
    for url in [
      root, root.appendingPathComponent("projects"), project(projectID), project(otherProjectID),
    ] {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
  }

  func project(_ id: UUID) -> URL {
    root.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(
      id.uuidString, isDirectory: true)
  }

  func configurationValue(initialize: Bool = true) throws -> CodexJSON {
    .object([
      "rootDirectory": .string(root.path), "initialize": .bool(initialize),
      "hostID": .string(hostID.uuidString),
      "projects": .array([projectID, otherProjectID].map { .string($0.uuidString) }),
      "devices": .array(
        [(fingerprint, deviceID), (otherFingerprint, otherDeviceID)].map { fingerprint, id in
          .object([
            "fingerprint": .string(fingerprint), "deviceID": .string(id.uuidString),
            "projectIDs": .array([.string(projectID.uuidString)]),
          ])
        }),
    ])
  }

  func open(initialize: Bool = true) async throws -> LedgerNetworkBridge {
    try await LedgerNetworkBridge.open(
      LedgerNetworkConfiguration.decode(configurationValue(initialize: initialize).encoded()))
  }

  func withReleasedBridge(_ operation: @Sendable (LedgerNetworkBridge) async throws -> Void)
    async throws
  {
    let released = try await perform(operation)
    try await released.wait()
  }

  private func perform(_ operation: @Sendable (LedgerNetworkBridge) async throws -> Void)
    async throws -> ReleasedOwner
  {
    let bridge = try await open()
    try await operation(bridge)
    return ReleasedOwner(ledger: bridge.ledger, directory: state)
  }

  func frame(
    operation: String = "accept", fingerprint: String? = nil, requestID: UUID? = nil,
    project: UUID? = nil, text: String = "é"
  ) throws -> Data {
    var fields: [String: CodexJSON] = [
      "operation": .string(operation),
      "peerFingerprint": .string(fingerprint ?? self.fingerprint),
      "requestID": .string((requestID ?? self.requestID).uuidString),
    ]
    if operation != "snapshot" {
      fields["projectID"] = .string((project ?? projectID).uuidString)
      fields["text"] = .string(text)
    }
    return try CodexJSON.object(fields).encoded()
  }

  func revoke() throws -> Data {
    try CodexJSON.object(["operation": .string("revoke"), "deviceID": .string(deviceID.uuidString)])
      .encoded()
  }

  func snapshot(_ phase: SubmissionPhase) -> CodexJSON {
    .object([
      "event": .string("result"), "state": .string("ledger-snapshot"),
      "requestID": .string(requestID.uuidString), "phase": .string(phase.rawValue),
    ])
  }

  func query(_ sql: String) throws -> [[String]] {
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        state.appendingPathComponent("submissions.sqlite3").path, &database, SQLITE_OPEN_READONLY,
        nil) == SQLITE_OK
    else {
      throw SubmissionError.invalidStorage
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw SubmissionError.invalidStorage
    }
    defer { sqlite3_finalize(statement) }
    var rows: [[String]] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else { throw SubmissionError.invalidStorage }
      rows.append(
        (0..<sqlite3_column_count(statement)).map {
          sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "NULL"
        })
    }
    return rows
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct ReleasedOwner: Sendable {
  weak var ledger: HostSubmissionLedger?
  let directory: URL

  func wait() async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while ledger != nil {
      guard clock.now < deadline else { throw SubmissionError.storeBusy }
      try await clock.sleep(for: .milliseconds(2))
    }
    let descriptor = open(
      directory.appendingPathComponent(".owner").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw SubmissionError.invalidStorage }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EAGAIN, clock.now < deadline else {
        throw SubmissionError.storeBusy
      }
      try await clock.sleep(for: .milliseconds(2))
    }
    guard flock(descriptor, LOCK_UN) == 0 else { throw SubmissionError.invalidStorage }
  }
}
