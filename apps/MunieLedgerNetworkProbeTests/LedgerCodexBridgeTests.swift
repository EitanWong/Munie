import Darwin
import Foundation
import MunieExecutionHost
import Testing

@testable import MunieLedgerNetworkProbe

struct LedgerCodexBridgeTests {
  @Test func unknownCrossDeviceProjectAndRevokedIdentitiesCannotDriveTheSession() async throws {
    let fixture = try CodexBridgeFixture()
    defer { fixture.remove() }
    let (facade, _, adapter) = try await fixture.facade()
    #expect(
      try await facade.respond(to: fixture.frame(fingerprint: String(repeating: "f", count: 64)))
        == denied("unauthorized"))
    #expect(
      try await facade.respond(to: fixture.frame(project: fixture.otherProjectID))
        == denied("unauthorized"))
    #expect(await adapter.startCount == 0)
    let started = try await facade.respond(to: fixture.frame())
    #expect(started.object?["phase"] == .string("running"))
    for operation in ["submit", "snapshot", "nextEvent", "interrupt", "reconcile"] {
      #expect(
        try await facade.respond(
          to: fixture.frame(operation: operation, fingerprint: fixture.otherFingerprint))
          == denied("unauthorized"))
    }
    _ = try await facade.respond(to: fixture.revoke())
    #expect(
      try await facade.respond(to: fixture.frame(requestID: UUID())) == denied("unauthorized"))
    for operation in ["submit", "snapshot", "nextEvent", "interrupt", "reconcile"] {
      #expect(
        try await facade.respond(to: fixture.frame(operation: operation)) == denied("unauthorized"))
    }
    #expect(await adapter.startCount == 1)
    #expect(await adapter.eventCount == 0)
    #expect(await adapter.interruptCount == 0)
  }

  @Test func approvalTokenIsBoundToAuthorizedOwnerAndOriginalContextAndConsumedOnce() async throws {
    let fixture = try CodexBridgeFixture()
    defer { fixture.remove() }
    let (facade, _, adapter) = try await fixture.facade(scenario: .approvalAccept)
    _ = try await facade.respond(to: fixture.frame())
    let approval = fixture.approval()
    await adapter.enqueue(fixture.event(.approval(approval)))
    let pending = try await facade.respond(to: fixture.frame(operation: "nextEvent"))
    let token = try #require(pending.object?["approvalToken"]?.string)
    #expect(pending.object?["eventKind"] == .string("approval"))
    #expect(pending.object?["agentMessageMatched"] == .bool(false))
    let snapshot = try await facade.respond(to: fixture.frame(operation: "snapshot"))
    #expect(snapshot.object?["approvalToken"]?.string == token)
    #expect(snapshot.object?["eventKind"] == nil)
    let reconciled = try await facade.respond(to: fixture.frame(operation: "reconcile"))
    #expect(reconciled.object?["approvalToken"]?.string == token)
    #expect(reconciled.object?["pendingApproval"] == .bool(true))
    #expect(
      try await facade.respond(to: fixture.answer(token: UUID().uuidString))
        == denied("invalid-approval"))
    #expect(
      try await facade.respond(
        to: fixture.answer(token: token, fingerprint: fixture.otherFingerprint))
        == denied("unauthorized"))
    #expect(
      try await facade.respond(to: fixture.answer(token: token, requestID: UUID()))
        == denied("unknown-request"))
    #expect(await adapter.decisions.isEmpty)
    let approved = try await facade.respond(to: fixture.answer(token: token))
    #expect(approved.object?["pendingApproval"] == .bool(false))
    #expect(approved.object?["approvalToken"] == nil)
    #expect(await adapter.decisions == [.accept])
    #expect(await adapter.lastApproval == approval)
    #expect(
      try await facade.respond(to: fixture.answer(token: token)) == denied("invalid-approval"))
    #expect(await adapter.decisions.count == 1)
    let output = try pending.encoded()
    for secret in [
      approval.command, approval.workingDirectory, "private-native-payload", "call_host",
    ] {
      #expect(output.range(of: Data(secret.utf8)) == nil)
    }
  }

  @Test func revocationAfterAnApprovalNeverAnswersOrLeaksThePendingToken() async throws {
    let fixture = try CodexBridgeFixture()
    defer { fixture.remove() }
    let (facade, _, adapter) = try await fixture.facade(scenario: .approvalCancel)
    _ = try await facade.respond(to: fixture.frame())
    await adapter.enqueue(fixture.event(.approval(fixture.approval())))
    let token = try #require(
      try await facade.respond(to: fixture.frame(operation: "nextEvent")).object?["approvalToken"]?
        .string)
    _ = try await facade.respond(to: fixture.revoke())
    #expect(
      try await facade.respond(to: fixture.answer(token: token, decision: "cancel"))
        == denied("unauthorized"))
    #expect(
      try await facade.respond(to: fixture.frame(operation: "snapshot")) == denied("unauthorized"))
    #expect(await adapter.decisions.isEmpty)
  }

  @Test func changedFixtureApprovalFailsClosedBeforeAnyTokenOrDecision() async throws {
    for changed in [
      "command", "directory", "reason", "options", "amendment", "extra-option", "item",
    ] {
      let fixture = try CodexBridgeFixture()
      defer { fixture.remove() }
      let (facade, _, adapter) = try await fixture.facade(scenario: .approvalAccept)
      _ = try await facade.respond(to: fixture.frame())
      await adapter.enqueue(fixture.event(.approval(fixture.approval(changed: changed))))
      await #expect(throws: (any Error).self) {
        try await facade.respond(to: fixture.frame(operation: "nextEvent"))
      }
      #expect(await adapter.decisions.isEmpty)
    }
  }

  @Test func terminalEventsDeduplicateAndOnlyExactNativeAgentTextMatches() async throws {
    let fixture = try CodexBridgeFixture()
    defer { fixture.remove() }
    let (facade, _, adapter) = try await fixture.facade()
    _ = try await facade.respond(to: fixture.frame())
    #expect(try await facade.respond(to: fixture.frame()).object?["phase"] == .string("running"))
    #expect(await adapter.startCount == 1)
    for text in ["MUNIE_FIXTURE_COMPLETE\n", "MUNIE_FIXTURE_COMPLETE"] {
      await adapter.enqueue(
        fixture.event(
          .progress, method: "item/completed",
          payload: .object([
            "item": .object(["type": .string("agentMessage"), "text": .string(text)])
          ])))
      let result = try await facade.respond(to: fixture.frame(operation: "nextEvent"))
      #expect(result.object?["agentMessageMatched"] == .bool(text == "MUNIE_FIXTURE_COMPLETE"))
    }
    await adapter.enqueue(
      fixture.event(.terminal(CodexTurnSnapshot(upstream: fixture.upstream, status: .completed))))
    let terminal = try await facade.respond(to: fixture.frame(operation: "nextEvent"))
    #expect(terminal.object?["phase"] == .string("completed"))
    #expect(terminal.object?["eventKind"] == .string("terminal"))
    let duplicate = try await facade.respond(to: fixture.frame(operation: "nextEvent"))
    #expect(duplicate.object?["eventKind"] == .string("none"))
    #expect(duplicate.object?["agentMessageMatched"] == .bool(false))
    #expect(try await facade.respond(to: fixture.frame()).object?["phase"] == .string("completed"))
    #expect(await adapter.startCount == 1)
    #expect(await adapter.eventCount == 3)
  }

  @Test func interruptAcknowledgmentNeedsAMatchingTerminalBeforeCancellation() async throws {
    let fixture = try CodexBridgeFixture()
    defer { fixture.remove() }
    let (facade, _, adapter) = try await fixture.facade(scenario: .runningInterrupt)
    _ = try await facade.respond(to: fixture.frame())
    let acknowledgment = try await facade.respond(to: fixture.frame(operation: "interrupt"))
    #expect(acknowledgment.object?["phase"] == .string("running"))
    #expect(acknowledgment.object?["cancellationRequested"] == .bool(true))
    _ = try await facade.respond(to: fixture.frame(operation: "interrupt"))
    #expect(await adapter.interruptCount == 1)
    await adapter.enqueue(
      fixture.event(.terminal(CodexTurnSnapshot(upstream: fixture.upstream, status: .interrupted))))
    #expect(
      try await facade.respond(to: fixture.frame(operation: "nextEvent")).object?["phase"]
        == .string("cancelled"))
  }

  @Test func strictCommandsForbidRPCIdentityConfigAndPersistentApprovalGrants() async throws {
    let fixture = try CodexBridgeFixture()
    defer { fixture.remove() }
    let (facade, _, adapter) = try await fixture.facade()
    var forged = try #require(CodexJSON.decode(fixture.frame()).object)
    for key in ["deviceID", "cwd", "config", "rpc", "scenario"] {
      var fields = forged
      fields[key] = .string("untrusted")
      #expect(
        try await facade.respond(to: CodexJSON.object(fields).encoded())
          == denied("invalid-request"))
    }
    forged["operation"] = .string("accept")
    #expect(
      try await facade.respond(to: CodexJSON.object(forged).encoded()) == denied("invalid-request"))
    for decision in ["acceptForSession", "decline", "true"] {
      #expect(
        try await facade.respond(to: fixture.answer(token: UUID().uuidString, decision: decision))
          == denied("invalid-request"))
    }
    #expect(
      try await facade.respond(
        to: Data("{\"operation\":\"snapshot\",\"operation\":\"submit\"}".utf8))
        == denied("invalid-request"))
    #expect(await adapter.startCount == 0)
  }

  @Test func reconnectReconcilesKnownUpstreamWithoutResendingAndKeepsRevocation() async throws {
    let fixture = try CodexBridgeFixture()
    defer { fixture.remove() }
    try await fixture.seedClosedTask()
    let config = try fixture.configuration(initialize: false)
    let bridge = try await LedgerNetworkBridge.open(config)
    let adapter = CodexBridgeAdapter(upstream: fixture.upstream)
    let session = try HostCodexSession(ledger: bridge.ledger, adapter: adapter)
    let facade = try LedgerCodexBridge(
      bridge: bridge, session: session, configuration: config, scenario: .text)
    #expect(
      try await facade.respond(to: fixture.frame()).object?["phase"] == .string("reconciling"))
    await adapter.setHistory(.completed)
    #expect(
      try await facade.respond(to: fixture.frame(operation: "reconcile")).object?["phase"]
        == .string("completed"))
    #expect(await adapter.startCount == 0)
    #expect(await adapter.readCount == 1)
    #expect(
      try await facade.respond(to: fixture.frame(fingerprint: fixture.otherFingerprint))
        == denied("unauthorized"))
    #expect(
      try await facade.respond(
        to: fixture.frame(operation: "reconcile", fingerprint: fixture.otherFingerprint))
        == denied("unauthorized"))
    _ = try await session.close()
  }

  @Test func initializationFailureRetainsBoundedActualTransportCleanupEvidence() async throws {
    let fixture = try CodexBridgeFixture()
    defer { fixture.remove() }
    for name in ["codex-data", "tmp"] {
      try FileManager.default.createDirectory(
        at: fixture.root.appendingPathComponent(name), withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    for name in ["sandbox.sb", "codex-data/config.toml", "guardian.py"] {
      let url = fixture.root.appendingPathComponent(name)
      #expect(
        FileManager.default.createFile(
          atPath: url.path, contents: Data("synthetic fixture".utf8),
          attributes: [.posixPermissions: 0o600]))
    }
    var runtime = try LedgerCodexRuntime(
      configuration: fixture.configuration(),
      arguments: [
        "/usr/bin/true", "/usr/bin/false", fixture.root.appendingPathComponent("guardian.py").path,
        "text",
      ])
    await #expect(throws: (any Error).self) { try await runtime.run() }
    let (cleanup, cleanupError) = await runtime.cleanupAfterFailure()
    #expect(cleanupError == .null)
    #expect(cleanup.object?["stdoutEOF"] == .bool(true))
    #expect(cleanup.object?["stderrEOF"] == .bool(true))
    #expect(cleanup.object?["groupGone"] == .bool(true))
    #expect(cleanup.object?["leaderExitStatus"]?.integer != nil)
    #expect(
      LedgerCodexRuntime.safeCode(NSError(domain: "synthetic-private-message", code: 42))
        == "unexpected-failure")
  }
}

private func denied(_ code: String) -> CodexJSON {
  .object(["event": .string("result"), "error": .string(code)])
}

private actor CodexBridgeAdapter: CodexExecutionAdapter {
  let upstream: UpstreamTurn
  var startCount = 0
  var eventCount = 0
  var interruptCount = 0
  var readCount = 0
  var decisions: [CodexApprovalDecision] = []
  var lastApproval: CodexCommandApproval?
  var events: [CodexNativeEvent] = []
  var history: CodexTurnStatus?
  init(upstream: UpstreamTurn) { self.upstream = upstream }
  func enqueue(_ event: CodexNativeEvent) { events.append(event) }
  func setHistory(_ status: CodexTurnStatus) { history = status }
  func start(_ submission: AuthorizedSubmission) async throws -> UpstreamTurn {
    startCount += 1
    return upstream
  }
  func nextEvent() async throws -> CodexNativeEvent {
    eventCount += 1
    guard !events.isEmpty else { throw HostCodexSessionError.noActiveTask }
    return events.removeFirst()
  }
  func interrupt(_ upstream: UpstreamTurn) async throws { interruptCount += 1 }
  func read(_ upstream: UpstreamTurn) async throws -> CodexTurnSnapshot? {
    readCount += 1
    return history.map { CodexTurnSnapshot(upstream: upstream, status: $0) }
  }
  func respondApproval(_ approval: CodexCommandApproval, decision: CodexApprovalDecision)
    async throws
  {
    lastApproval = approval
    decisions.append(decision)
  }
  func close() async throws -> CodexTransportCleanup {
    CodexTransportCleanup(
      leaderExitStatus: 0, stdoutEOF: true, stderrEOF: true, groupGone: true, escalated: false,
      stdinBytes: 0, stdoutBytes: 0, stderrBytes: 0)
  }
}

private struct CodexBridgeFixture: Sendable {
  let root: URL
  let hostID = UUID()
  let projectID = UUID()
  let otherProjectID = UUID()
  let deviceID = UUID()
  let otherDeviceID = UUID()
  let requestID = UUID()
  let fingerprint = String(repeating: "a", count: 64)
  let otherFingerprint = String(repeating: "b", count: 64)
  let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())
  var project: URL {
    root.appendingPathComponent("projects/\(projectID.uuidString)", isDirectory: true)
  }

  init() throws {
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw SubmissionError.invalidStorage
    }
    defer { free(resolved) }
    root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
      .appendingPathComponent("munie-codex-network-\(UUID().uuidString)", isDirectory: true)
    for url in [
      root, root.appendingPathComponent("projects"), project,
      root.appendingPathComponent("projects/\(otherProjectID.uuidString)"),
    ] {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
  }

  func configuration(initialize: Bool = true) throws -> LedgerNetworkConfiguration {
    try LedgerNetworkConfiguration.decode(
      CodexJSON.object([
        "rootDirectory": .string(root.path), "initialize": .bool(initialize),
        "hostID": .string(hostID.uuidString),
        "projects": .array([.string(projectID.uuidString), .string(otherProjectID.uuidString)]),
        "devices": .array(
          [(fingerprint, deviceID), (otherFingerprint, otherDeviceID)].map { fp, id in
            .object([
              "fingerprint": .string(fp), "deviceID": .string(id.uuidString),
              "projectIDs": .array([.string(projectID.uuidString)]),
            ])
          }),
      ]).encoded())
  }

  func facade(scenario: LedgerCodexScenario = .text) async throws -> (
    LedgerCodexBridge, HostCodexSession, CodexBridgeAdapter
  ) {
    let config = try configuration()
    let bridge = try await LedgerNetworkBridge.open(config)
    let adapter = CodexBridgeAdapter(upstream: upstream)
    let session = try HostCodexSession(ledger: bridge.ledger, adapter: adapter)
    return (
      try LedgerCodexBridge(
        bridge: bridge, session: session, configuration: config, scenario: scenario), session,
      adapter
    )
  }

  func frame(
    operation: String = "submit", fingerprint: String? = nil, requestID: UUID? = nil,
    project: UUID? = nil
  ) throws -> Data {
    var fields: [String: CodexJSON] = [
      "operation": .string(operation), "peerFingerprint": .string(fingerprint ?? self.fingerprint),
      "requestID": .string((requestID ?? self.requestID).uuidString),
    ]
    if operation == "submit" {
      fields["projectID"] = .string((project ?? projectID).uuidString)
      fields["text"] = .string("synthetic task")
    }
    return try CodexJSON.object(fields).encoded()
  }

  func answer(
    token: String, fingerprint: String? = nil, requestID: UUID? = nil, decision: String = "accept"
  ) throws -> Data {
    try CodexJSON.object([
      "operation": .string("approval"), "peerFingerprint": .string(fingerprint ?? self.fingerprint),
      "requestID": .string((requestID ?? self.requestID).uuidString),
      "approvalToken": .string(token), "decision": .string(decision),
    ]).encoded()
  }

  func revoke() throws -> Data {
    try CodexJSON.object(["operation": .string("revoke"), "deviceID": .string(deviceID.uuidString)])
      .encoded()
  }

  func approval(changed: String? = nil) -> CodexCommandApproval {
    var decisions = LedgerCodexScenario.fixtureDecisions(
      command: changed == "amendment" ? "/bin/echo unexpected" : LedgerCodexScenario.effectCommand)
    if changed == "options" { decisions = [.string("accept")] }
    if changed == "extra-option" { decisions.append(.string("acceptForSession")) }
    return CodexCommandApproval(
      rpcID: .integer(7), upstream: upstream,
      itemID: changed == "item" ? "different" : "call_host",
      command: changed == "command"
        ? "/bin/echo unexpected" : "/bin/sh -c '\(LedgerCodexScenario.effectCommand)'",
      workingDirectory: changed == "directory" ? root.path : project.path,
      reason: changed == "reason" ? "unexpected" : "Munie native host fixture approval",
      availableDecisions: decisions,
      payload: .object(["opaque": .string("private-native-payload")]))
  }

  func event(
    _ kind: CodexNativeEvent.Kind, method: String = "fixture/event",
    payload: CodexJSON = .object([:])
  ) -> CodexNativeEvent {
    CodexNativeEvent(
      method: method, requestID: requestID, threadID: upstream.threadID, turnID: upstream.turnID,
      itemID: { if case .approval(let approval) = kind { approval.itemID } else { nil } }(),
      kind: kind, payload: payload)
  }

  func seedClosedTask() async throws {
    let owner = try await performSeed()
    try await owner.wait()
  }

  private func performSeed() async throws -> CodexReleasedOwner {
    let config = try configuration()
    let bridge = try await LedgerNetworkBridge.open(config)
    let adapter = CodexBridgeAdapter(upstream: upstream)
    let session = try HostCodexSession(ledger: bridge.ledger, adapter: adapter)
    _ = try await session.submit(
      TextSubmission(
        requestID: requestID, hostID: hostID, projectID: projectID, text: "synthetic task"),
      from: AuthenticatedDevice(id: deviceID))
    try await bridge.ledger.revokeDevice(id: otherDeviceID)
    _ = try await session.close()
    return CodexReleasedOwner(ledger: bridge.ledger, state: root.appendingPathComponent("state"))
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct CodexReleasedOwner: Sendable {
  weak var ledger: HostSubmissionLedger?
  let state: URL
  func wait() async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while ledger != nil {
      guard clock.now < deadline else { throw SubmissionError.storeBusy }
      try await clock.sleep(for: .milliseconds(2))
    }
    let fd = open(state.appendingPathComponent(".owner").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw SubmissionError.invalidStorage }
    defer { close(fd) }
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard [EWOULDBLOCK, EAGAIN].contains(errno), clock.now < deadline else {
        throw SubmissionError.storeBusy
      }
      try await clock.sleep(for: .milliseconds(2))
    }
    guard flock(fd, LOCK_UN) == 0 else { throw SubmissionError.invalidStorage }
  }
}
