import Darwin
import Foundation
import Testing

@testable import MunieExecutionHost

struct HostSubmissionLedgerTests {
  @Test func textValidationAndDigestPreserveExactUTF8() throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    for text in ["", " \n\t", String(repeating: "🔒", count: 8_193)] {
      #expect(throws: SubmissionError.invalidInput) { try fixture.request(text: text) }
    }
    let exact = try fixture.request(text: " \nMunie 🔒 e\u{301}\n")
    #expect(exact.text.utf8.elementsEqual(" \nMunie 🔒 e\u{301}\n".utf8))
    #expect(
      exact.payloadDigest == "aad0f8f21c995b7ce2d9e8a54868f825a9bc9637e25b53155f4eb990a2dbe1a3")
    #expect(
      try fixture.request(text: String(repeating: "🔒", count: 8_192)).text.utf8.count == 32_768)
  }

  @Test func acceptanceRequiresTheHostProjectAndAuthorizedDevice() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let request = try fixture.request()
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.accept(request, from: AuthenticatedDevice(id: UUID()))
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.accept(fixture.request(host: UUID()), from: fixture.device)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.accept(fixture.request(project: UUID()), from: fixture.device)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.accept(
        fixture.request(project: fixture.otherProjectID), from: fixture.device)
    }
    #expect(try await ledger.accept(request, from: fixture.device).phase == .accepted)
  }

  @Test func invalidAuthorizationDoesNotPartiallyReplaceExistingGrants() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.authorizeDevice(
        id: fixture.device.id, projects: [fixture.otherProjectID, UUID()])
    }
    #expect(try await ledger.accept(fixture.request(), from: fixture.device).phase == .accepted)
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.accept(
        fixture.request(project: fixture.otherProjectID), from: fixture.device)
    }
  }

  @Test func revokedAuthenticatedIdentityCannotAcceptClaimOrRead() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let request = try fixture.request()
    try await ledger.accept(request, from: fixture.device)
    try await ledger.revokeDevice(id: fixture.device.id)
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.accept(request, from: fixture.device)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.claimForDispatch(request, from: fixture.device)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.snapshot(requestID: request.requestID, from: fixture.device)
    }
  }

  @Test func revocationPersistsAcrossLedgerRestart() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let request = try fixture.request()
    try await fixture.withReleasedLedger { ledger in
      try await ledger.accept(request, from: fixture.device)
      try await ledger.revokeDevice(id: fixture.device.id)
    }
    let reopened = try fixture.reopen()
    await #expect(throws: SubmissionError.unauthorized) {
      try await reopened.snapshot(requestID: request.requestID, from: fixture.device)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await reopened.claimForDispatch(request, from: fixture.device)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await reopened.authorizeDevice(id: fixture.device.id, projects: [fixture.projectID])
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await reopened.snapshot(requestID: request.requestID, from: fixture.device)
    }
  }

  @Test func revokingAnUnknownIdentityPreventsLaterRegistrationAndSurvivesRestart() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let unknown = AuthenticatedDevice(id: UUID())
    try await fixture.withReleasedLedger { ledger in
      try await ledger.revokeDevice(id: unknown.id)
      await #expect(throws: SubmissionError.unauthorized) {
        try await ledger.authorizeDevice(id: unknown.id, projects: [fixture.projectID])
      }
      await #expect(throws: SubmissionError.unauthorized) {
        try await ledger.accept(fixture.request(), from: unknown)
      }
    }
    let reopened = try fixture.reopen()
    await #expect(throws: SubmissionError.unauthorized) {
      try await reopened.authorizeDevice(id: unknown.id, projects: [fixture.projectID])
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await reopened.accept(fixture.request(), from: unknown)
    }
    #expect(try await reopened.accept(fixture.request(), from: fixture.device).phase == .accepted)
  }

  @Test func duplicateAcceptanceAndClaimsNeverIssueASecondDispatch() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let request = try fixture.request(text: " Preserve this exact text.\n")
    let accepted = try await ledger.accept(request, from: fixture.device)
    #expect(try await ledger.accept(request, from: fixture.device) == accepted)
    let first = try await ledger.claimForDispatch(request, from: fixture.device)
    guard case .send(let authorized) = first else {
      Issue.record("First accepted request did not receive its dispatch claim")
      return
    }
    #expect(authorized.request.requestID == request.requestID)
    #expect(authorized.request.text.utf8.elementsEqual(request.text.utf8))
    #expect(authorized.workingDirectory.path == fixture.projectURL.path)
    #expect(try await ledger.accept(request, from: fixture.device).phase == .dispatching)
    #expect(
      try await ledger.snapshot(requestID: request.requestID, from: fixture.device).phase
        == .dispatching)
    let duplicate = try await ledger.claimForDispatch(request, from: fixture.device)
    guard case .existing(let snapshot) = duplicate else {
      Issue.record("Duplicate claim would dispatch a second time")
      return
    }
    #expect(snapshot.phase == .dispatching)
    #expect(snapshot.upstream == nil)
  }

  @Test func requestIdentityRejectsWhitespaceAndUnicodeByteChanges() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let request = try fixture.request(text: "é")
    try await ledger.accept(request, from: fixture.device)
    #expect("é" == "e\u{301}")
    for changed in [" é", "é\n", "e\u{301}"] {
      let conflict = try fixture.request(id: request.requestID, text: changed)
      await #expect(throws: SubmissionError.requestConflict) {
        try await ledger.accept(conflict, from: fixture.device)
      }
      await #expect(throws: SubmissionError.requestConflict) {
        try await ledger.claimForDispatch(conflict, from: fixture.device)
      }
    }
    #expect(
      try await ledger.snapshot(requestID: request.requestID, from: fixture.device).phase
        == .accepted)
  }

  @Test func requestIdentityCannotMoveToAnotherAuthorizedProjectOrThread() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    try await ledger.authorizeDevice(
      id: fixture.device.id, projects: [fixture.projectID, fixture.otherProjectID])
    let initial = try fixture.request()
    try await ledger.accept(initial, from: fixture.device)
    let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())
    _ = try await ledger.claimForDispatch(initial, from: fixture.device)
    try await ledger.observeStarted(requestID: initial.requestID, upstream: upstream)
    let pending = try fixture.request()
    try await ledger.accept(pending, from: fixture.device)
    for changed in [
      try fixture.request(id: pending.requestID, project: fixture.otherProjectID),
      try fixture.request(id: pending.requestID, thread: upstream.threadID),
    ] {
      await #expect(throws: SubmissionError.requestConflict) {
        try await ledger.accept(changed, from: fixture.device)
      }
    }
    #expect(
      try await ledger.snapshot(requestID: pending.requestID, from: fixture.device).phase
        == .accepted)
  }

  @Test func anotherAuthorizedDeviceCannotReadOrReuseAnExistingRequestID() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let otherDevice = AuthenticatedDevice(id: UUID())
    try await ledger.authorizeDevice(id: otherDevice.id, projects: [fixture.projectID])
    let request = try fixture.request()
    try await ledger.accept(request, from: fixture.device)
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.snapshot(requestID: request.requestID, from: otherDevice)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.accept(request, from: otherDevice)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.claimForDispatch(request, from: otherDevice)
    }
    #expect(
      try await ledger.snapshot(requestID: request.requestID, from: fixture.device).phase
        == .accepted)
  }

  @Test func unknownRequestsAndUnmappedThreadsAreNotExecutable() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let unknown = try fixture.request()
    await #expect(throws: SubmissionError.unknownRequest) {
      try await ledger.claimForDispatch(unknown, from: fixture.device)
    }
    await #expect(throws: SubmissionError.unknownRequest) {
      try await ledger.snapshot(requestID: unknown.requestID, from: fixture.device)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.accept(fixture.request(thread: UUID()), from: fixture.device)
    }
  }

  @Test func mappedThreadCanResumeOnlyWithinItsOriginalProject() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    try await ledger.authorizeDevice(
      id: fixture.device.id, projects: [fixture.projectID, fixture.otherProjectID])
    let initial = try fixture.request()
    try await ledger.accept(initial, from: fixture.device)
    _ = try await ledger.claimForDispatch(initial, from: fixture.device)
    let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())
    try await ledger.observeStarted(requestID: initial.requestID, upstream: upstream)
    try await ledger.observeTerminal(
      requestID: initial.requestID, upstream: upstream, phase: .completed)
    await #expect(throws: SubmissionError.unauthorized) {
      try await ledger.accept(
        fixture.request(project: fixture.otherProjectID, thread: upstream.threadID),
        from: fixture.device)
    }
    let resumed = try fixture.request(thread: upstream.threadID)
    try await ledger.accept(resumed, from: fixture.device)
    guard
      case .send(let authorized) = try await ledger.claimForDispatch(resumed, from: fixture.device)
    else {
      Issue.record("A known project-scoped thread could not receive a new request")
      return
    }
    #expect(authorized.request.threadID == upstream.threadID)
    let next = UpstreamTurn(threadID: upstream.threadID, turnID: UUID())
    try await ledger.observeStarted(requestID: resumed.requestID, upstream: next)
    #expect(
      try await ledger.snapshot(requestID: resumed.requestID, from: fixture.device).upstream == next
    )
  }

  @Test func upstreamAndTerminalTransitionsRequireMatchingPositiveEvidence() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let request = try fixture.request()
    try await ledger.accept(request, from: fixture.device)
    let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())
    await #expect(throws: SubmissionError.upstreamConflict) {
      try await ledger.observeStarted(requestID: request.requestID, upstream: upstream)
    }
    await #expect(throws: SubmissionError.invalidTransition) {
      try await ledger.markUncertain(requestID: request.requestID)
    }
    _ = try await ledger.claimForDispatch(request, from: fixture.device)
    try await ledger.observeStarted(requestID: request.requestID, upstream: upstream)
    try await ledger.observeStarted(requestID: request.requestID, upstream: upstream)
    let wrong = UpstreamTurn(threadID: upstream.threadID, turnID: UUID())
    await #expect(throws: SubmissionError.upstreamConflict) {
      try await ledger.observeStarted(requestID: request.requestID, upstream: wrong)
    }
    await #expect(throws: SubmissionError.upstreamConflict) {
      try await ledger.observeTerminal(
        requestID: request.requestID, upstream: wrong, phase: .completed)
    }
    await #expect(throws: SubmissionError.invalidTransition) {
      try await ledger.observeTerminal(
        requestID: request.requestID, upstream: upstream, phase: .running)
    }
    #expect(
      try await ledger.snapshot(requestID: request.requestID, from: fixture.device).phase
        == .running)
    try await ledger.observeTerminal(
      requestID: request.requestID, upstream: upstream, phase: .completed)
    try await ledger.observeTerminal(
      requestID: request.requestID, upstream: upstream, phase: .completed)
    await #expect(throws: SubmissionError.invalidTransition) {
      try await ledger.observeTerminal(
        requestID: request.requestID, upstream: upstream, phase: .failed)
    }
    #expect(
      try await ledger.snapshot(requestID: request.requestID, from: fixture.device).phase
        == .completed)
  }

  @Test func resumedRequestCannotBeMappedToADifferentUpstreamThread() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let initial = try fixture.request()
    try await ledger.accept(initial, from: fixture.device)
    _ = try await ledger.claimForDispatch(initial, from: fixture.device)
    let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())
    try await ledger.observeStarted(requestID: initial.requestID, upstream: upstream)
    let resumed = try fixture.request(thread: upstream.threadID)
    try await ledger.accept(resumed, from: fixture.device)
    _ = try await ledger.claimForDispatch(resumed, from: fixture.device)
    await #expect(throws: SubmissionError.upstreamConflict) {
      try await ledger.observeStarted(
        requestID: resumed.requestID, upstream: UpstreamTurn(threadID: UUID(), turnID: UUID()))
    }
    #expect(
      try await ledger.snapshot(requestID: resumed.requestID, from: fixture.device).phase
        == .dispatching)
  }

  @Test func upstreamIdentityCannotCrossRequestsOrProjects() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    try await ledger.authorizeDevice(
      id: fixture.device.id, projects: [fixture.projectID, fixture.otherProjectID])
    let first = try fixture.request()
    let second = try fixture.request()
    let otherProject = try fixture.request(project: fixture.otherProjectID)
    for request in [first, second, otherProject] {
      try await ledger.accept(request, from: fixture.device)
      _ = try await ledger.claimForDispatch(request, from: fixture.device)
    }
    let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())
    try await ledger.observeStarted(requestID: first.requestID, upstream: upstream)
    await #expect(throws: SubmissionError.upstreamConflict) {
      try await ledger.observeStarted(requestID: second.requestID, upstream: upstream)
    }
    await #expect(throws: SubmissionError.upstreamConflict) {
      try await ledger.observeStarted(
        requestID: otherProject.requestID,
        upstream: UpstreamTurn(threadID: upstream.threadID, turnID: UUID()))
    }
    #expect(
      try await ledger.snapshot(requestID: second.requestID, from: fixture.device).phase
        == .dispatching)
    let unchanged = try await ledger.snapshot(
      requestID: otherProject.requestID, from: fixture.device)
    #expect(unchanged.phase == .dispatching)
    #expect(unchanged.upstream == nil)
  }

  @Test func restartedDispatchingAndRunningRequestsReconcileWithoutNewClaims() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let dispatching = try fixture.request()
    let running = try fixture.request()
    let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())
    try await fixture.withReleasedLedger { ledger in
      for request in [dispatching, running] {
        try await ledger.accept(request, from: fixture.device)
        _ = try await ledger.claimForDispatch(request, from: fixture.device)
      }
      try await ledger.observeStarted(requestID: running.requestID, upstream: upstream)
    }
    let reopened = try fixture.reopen()
    for request in [dispatching, running] {
      guard
        case .existing(let existing) = try await reopened.claimForDispatch(
          request, from: fixture.device)
      else {
        Issue.record("Restart issued a new dispatch for an uncertain request")
        continue
      }
      #expect(existing.phase == .reconciling)
      #expect(existing.upstream == (request.requestID == running.requestID ? upstream : nil))
    }
    try await reopened.observeTerminal(
      requestID: running.requestID, upstream: upstream, phase: .cancelled)
    #expect(
      try await reopened.snapshot(requestID: running.requestID, from: fixture.device).phase
        == .cancelled)
  }

  @Test func concurrentDuplicateClaimsYieldExactlyOneLocalDispatch() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let request = try fixture.request()
    try await ledger.accept(request, from: fixture.device)
    let sendCount = try await withThrowingTaskGroup(of: Bool.self) { group in
      for _ in 0..<32 {
        group.addTask {
          switch try await ledger.claimForDispatch(request, from: fixture.device) {
          case .send: return true
          case .existing(let snapshot):
            #expect(snapshot.phase == .dispatching)
            return false
          }
        }
      }
      var count = 0
      for try await sent in group where sent { count += 1 }
      return count
    }
    #expect(sendCount == 1)
  }

  @Test func symlinkReplacementBetweenAcceptAndClaimIsRejected() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let request = try fixture.request()
    try await ledger.accept(request, from: fixture.device)
    let original = fixture.root.appendingPathComponent("original-project")
    try FileManager.default.moveItem(at: fixture.projectURL, to: original)
    try FileManager.default.createSymbolicLink(
      at: fixture.projectURL, withDestinationURL: fixture.otherProjectURL)
    await #expect(throws: SubmissionError.projectChanged) {
      try await ledger.claimForDispatch(request, from: fixture.device)
    }
    try FileManager.default.removeItem(at: fixture.projectURL)
    try FileManager.default.moveItem(at: original, to: fixture.projectURL)
    #expect(
      try await ledger.snapshot(requestID: request.requestID, from: fixture.device).phase
        == .accepted)
  }

  @Test func inodeReplacementBetweenAcceptAndClaimIsRejected() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.authorizedLedger()
    let request = try fixture.request()
    try await ledger.accept(request, from: fixture.device)
    let original = fixture.root.appendingPathComponent("original-project")
    try FileManager.default.moveItem(at: fixture.projectURL, to: original)
    try FileManager.default.createDirectory(
      at: fixture.projectURL, withIntermediateDirectories: false)
    await #expect(throws: SubmissionError.projectChanged) {
      try await ledger.claimForDispatch(request, from: fixture.device)
    }
    try FileManager.default.removeItem(at: fixture.projectURL)
    try FileManager.default.moveItem(at: original, to: fixture.projectURL)
    #expect(
      try await ledger.snapshot(requestID: request.requestID, from: fixture.device).phase
        == .accepted)
  }

  @Test func conflictingHostCannotMutateTheExistingLedger() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let request = try fixture.request()
    let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())
    try await fixture.withReleasedLedger { ledger in
      try await ledger.accept(request, from: fixture.device)
      _ = try await ledger.claimForDispatch(request, from: fixture.device)
      try await ledger.observeStarted(requestID: request.requestID, upstream: upstream)
    }
    #expect(throws: SubmissionError.invalidStorage) {
      try HostSubmissionLedger(directoryURL: fixture.storeURL, hostID: UUID())
    }
    try await fixture.withReleasedStorage { storage in
      let phases = try storage.rows("SELECT phase FROM requests")
      #expect(phases == [[.text("running")]])
    }
    let reopened = try fixture.reopen()
    let recovered = try await reopened.snapshot(requestID: request.requestID, from: fixture.device)
    #expect(recovered.phase == .reconciling)
    #expect(recovered.upstream == upstream)
  }

  @Test func unsupportedSchemaPreservesRequestsAndVersion() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let request = try fixture.request()
    try await fixture.withReleasedLedger { ledger in
      try await ledger.accept(request, from: fixture.device)
    }
    let before = try await fixture.withReleasedStorage { storage in
      try storage.run("PRAGMA user_version=99")
      return try storage.rows("SELECT id,identity,phase FROM requests")
    }
    #expect(throws: SubmissionError.unsupportedSchema) { try fixture.reopen() }
    try await fixture.withReleasedStorage { storage in
      #expect(try storage.rows("PRAGMA user_version") == [[.integer(99)]])
      #expect(try storage.rows("SELECT id,identity,phase FROM requests") == before)
      try storage.run("PRAGMA user_version=1")
    }
    let reopened = try fixture.reopen()
    #expect(
      try await reopened.snapshot(requestID: request.requestID, from: fixture.device).phase
        == .accepted)
  }

  @Test func unversionedForeignDatabaseIsRejectedWithoutDroppingItsData() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    try await fixture.withReleasedStorage { storage in
      try storage.run("CREATE TABLE foreign_data(value TEXT NOT NULL)")
      try storage.run("INSERT INTO foreign_data(value) VALUES('preserve-me')")
    }
    #expect(throws: SubmissionError.unsupportedSchema) { try fixture.reopen() }
    let storage = try SQLiteStorage(directoryURL: fixture.storeURL)
    #expect(try storage.rows("SELECT value FROM foreign_data") == [[.text("preserve-me")]])
    #expect(try storage.rows("PRAGMA user_version") == [[.integer(0)]])
  }

  @Test func requestBodyIsAbsentFromSQLiteAndItsSidecars() async throws {
    let fixture = try LedgerFixture()
    defer { fixture.remove() }
    let plaintext = "MUNIE_PRIVATE_TEST_BODY_" + String(repeating: "不可落盘-private-🔒", count: 24)
    let request = try fixture.request(text: plaintext)
    try await fixture.withReleasedLedger { ledger in
      try await ledger.accept(request, from: fixture.device)
      _ = try await ledger.claimForDispatch(request, from: fixture.device)
      let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())
      try await ledger.observeStarted(requestID: request.requestID, upstream: upstream)
      try await ledger.observeTerminal(
        requestID: request.requestID, upstream: upstream, phase: .completed)
      try assertNoPlaintext(in: fixture.storeURL, text: plaintext)
    }
    let storage = try SQLiteStorage(directoryURL: fixture.storeURL)
    let rows = try storage.rows("SELECT identity FROM requests")
    let row = try #require(rows.first)
    guard case .text(let json) = try #require(row.first) else {
      Issue.record("Missing durable request identity")
      return
    }
    let identity = try JSONDecoder().decode(SubmissionIdentity.self, from: Data(json.utf8))
    #expect(identity.payloadDigest == request.payloadDigest)
    #expect(identity.deviceID == fixture.device.id)
    #expect(identity.hostID == fixture.hostID)
    #expect(identity.projectID == fixture.projectID)
    try assertNoPlaintext(in: fixture.storeURL, text: plaintext)
  }
}

private struct LedgerFixture: Sendable {
  let root: URL
  let storeURL: URL
  let projectURL: URL
  let otherProjectURL: URL
  let hostID = UUID()
  let projectID = UUID()
  let otherProjectID = UUID()
  let device = AuthenticatedDevice(id: UUID())

  init() throws {
    guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw CocoaError(.fileReadUnknown)
    }
    defer { free(canonical) }
    root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
      .appendingPathComponent("munie-ledger-tests-\(UUID().uuidString)", isDirectory: true)
    storeURL = root.appendingPathComponent("store", isDirectory: true)
    projectURL = root.appendingPathComponent("project", isDirectory: true)
    otherProjectURL = root.appendingPathComponent("other-project", isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherProjectURL, withIntermediateDirectories: true)
  }

  func authorizedLedger() async throws -> HostSubmissionLedger {
    let ledger = try reopen()
    try await ledger.registerProject(id: projectID, directoryURL: projectURL)
    try await ledger.registerProject(id: otherProjectID, directoryURL: otherProjectURL)
    try await ledger.authorizeDevice(id: device.id, projects: [projectID])
    return ledger
  }

  func reopen() throws -> HostSubmissionLedger {
    try HostSubmissionLedger(directoryURL: storeURL, hostID: hostID)
  }

  func withReleasedLedger(
    _ operation: @Sendable (HostSubmissionLedger) async throws -> Void
  ) async throws {
    let previous = try await performLedgerOperation(operation)
    try await previous.wait()
  }

  private func performLedgerOperation(
    _ operation: @Sendable (HostSubmissionLedger) async throws -> Void
  ) async throws -> HostFixtureOwnerRelease {
    let ledger = try await authorizedLedger()
    try await operation(ledger)
    return HostFixtureOwnerRelease(ledger: ledger, store: storeURL)
  }

  func withReleasedStorage<Value: Sendable>(
    _ operation: (SQLiteStorage) throws -> Value
  ) async throws -> Value {
    let value = try performStorageOperation(operation)
    try await HostFixtureOwnerRelease(store: storeURL).wait()
    return value
  }

  private func performStorageOperation<Value>(
    _ operation: (SQLiteStorage) throws -> Value
  ) throws -> Value {
    let storage = try SQLiteStorage(directoryURL: storeURL)
    return try operation(storage)
  }

  func request(
    id: UUID = UUID(), host: UUID? = nil, project: UUID? = nil,
    thread: UUID? = nil, text: String = "Synthetic ledger request"
  ) throws -> TextSubmission {
    try TextSubmission(
      requestID: id, hostID: host ?? hostID, projectID: project ?? projectID,
      threadID: thread, text: text)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func assertNoPlaintext(in directory: URL, text: String) throws {
  let files = try #require(
    FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
  var checked = 0
  for case let file as URL in files {
    if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      let data = try Data(contentsOf: file)
      #expect(data.range(of: Data(text.utf8)) == nil)
      #expect(data.range(of: Data("MUNIE_PRIVATE_TEST_BODY_".utf8)) == nil)
      checked += 1
    }
  }
  #expect(checked > 0)
}
