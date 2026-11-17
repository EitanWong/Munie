import Darwin
import Foundation
import Testing

@testable import MunieExecutionHost

struct CodexAppServerTests {
  @Test func canonicallyEquivalentPathBytesCannotReplaceTheConfiguredDirectoryOrHome() async throws
  {
    let root = ClientFixture.directory.appendingPathComponent("munie-unicode-\(UUID().uuidString)")
    let requested = root.appendingPathComponent("caf\u{e9}", isDirectory: true)
    try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let resolved = try #require(realpath(requested.path, nil))
    defer { free(resolved) }
    let path = String(cString: resolved)
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    let decomposed = path.decomposedStringWithCanonicalMapping
    let alternate =
      path.utf8.elementsEqual(decomposed.utf8)
      ? path.precomposedStringWithCanonicalMapping : decomposed
    #expect(path == alternate)
    #expect(!path.utf8.elementsEqual(alternate.utf8))

    let wrongHome = try ClientFixture(
      initialization: ClientFixture.initialize(home: alternate), directoryURL: directory,
      codexHomeURL: directory)
    await #expect(throws: CodexClientError.unsupportedVersion) {
      try await wrongHome.client.initialize()
    }
    _ = try await wrongHome.client.close()

    var wrong = ClientFixture.thread().object!
    wrong["cwd"] = .string(alternate)
    wrong["thread"] = .object([
      "id": .string(ClientFixture.threadID.uuidString.lowercased()), "cwd": .string(alternate),
    ])
    let wrongThread = try ClientFixture(
      initialization: ClientFixture.initialize(home: path), thread: .object(wrong),
      directoryURL: directory, codexHomeURL: directory)
    try await wrongThread.client.initialize()
    await #expect(throws: CodexClientError.identityMismatch) {
      try await wrongThread.client.start(wrongThread.submission())
    }
    _ = try await wrongThread.client.close()
  }

  @Test func canonicallyEquivalentCommandBytesDoNotMatchTheStartedAction() async throws {
    let composed = "echo caf\u{e9}"
    let decomposed = "echo cafe\u{301}"
    #expect(composed == decomposed)
    let fixture = try ClientFixture()
    try await fixture.start()
    await fixture.peer.push(.event(ClientFixture.itemStarted(command: composed)))
    _ = try await fixture.client.nextEvent()
    await fixture.peer.push(.event(ClientFixture.approval(command: decomposed)))
    await #expect(throws: CodexClientError.unsupportedMethod) {
      try await fixture.client.nextEvent()
    }
    _ = try await fixture.client.close()
  }

  @Test func approvalEqualityAndReplyRequireExactNativeUTF8Bytes() async throws {
    let composed = "caf\u{e9}"
    let decomposed = "cafe\u{301}"
    #expect(composed == decomposed)
    #expect(CodexRPCID.string(composed) != .string(decomposed))
    #expect(Set([CodexRPCID.string(composed), .string(decomposed)]).count == 2)
    let fixture = try ClientFixture()
    try await fixture.start()
    await fixture.peer.push(.event(ClientFixture.itemStarted(command: composed)))
    _ = try await fixture.client.nextEvent()
    await fixture.peer.push(.event(ClientFixture.approval(command: composed)))
    let event = try await fixture.client.nextEvent()
    guard case .approval(let approval) = event.kind else { throw CodexClientError.malformedFrame }
    let changed = CodexCommandApproval(
      rpcID: approval.rpcID, upstream: approval.upstream, itemID: approval.itemID,
      command: decomposed, workingDirectory: approval.workingDirectory, reason: approval.reason,
      availableDecisions: approval.availableDecisions, payload: approval.payload)
    #expect(changed != approval)
    let before = await fixture.peer.sent.count
    await #expect(throws: CodexClientError.staleApproval) {
      try await fixture.client.respondApproval(changed, decision: .accept)
    }
    #expect(await fixture.peer.sent.count == before)
    try await fixture.client.respondApproval(approval, decision: .accept)
    _ = try await fixture.client.close()
  }

  @Test func canonicalPrivatePathIsPreservedAndAliasIsRejected() throws {
    let peer = ClientPeer(steps: [])
    _ = try CodexAppServer(
      transport: peer, workingDirectoryURL: ClientFixture.directory,
      codexHomeURL: ClientFixture.home)
    #expect(ClientFixture.directory.path == "/private/tmp")
    #expect(throws: CodexClientError.invalidConfiguration) {
      try CodexAppServer(
        transport: peer, workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
        codexHomeURL: ClientFixture.home)
    }
  }
  @Test func handshakeIsVersionBoundAndOccursExactlyOnce() async throws {
    let fixture = try ClientFixture()
    try await fixture.client.initialize()
    await #expect(throws: CodexClientError.alreadyInitialized) {
      try await fixture.client.initialize()
    }
    let sent = await fixture.peer.sent
    #expect(sent.count == 2)
    #expect(sent[0].object?["method"] == .string("initialize"))
    #expect(sent[1].object?["method"] == .string("initialized"))
    _ = try await fixture.client.close()
  }

  @Test func unknownVersionAndWrongDataHomeRejectBeforeInitializedNotification() async throws {
    for result in [
      ClientFixture.initialize(version: "0.163.0"), ClientFixture.initialize(home: "/other"),
    ] {
      let fixture = try ClientFixture(initialization: result)
      await #expect(throws: CodexClientError.unsupportedVersion) {
        try await fixture.client.initialize()
      }
      #expect(await fixture.peer.sent.count == 1)
      _ = try await fixture.client.close()
    }
  }

  @Test func nativeNotificationTimestampEnvelopeIsAcceptedButWrongTypeIsRejected() async throws {
    let fixture = try ClientFixture()
    try await fixture.start()
    await fixture.peer.push(
      .event(
        .object([
          "method": .string("remoteControl/status/changed"), "emittedAtMs": .integer(1),
          "params": .object(["status": .string("disabled")]),
        ])))
    #expect(try await fixture.client.nextEvent().method == "remoteControl/status/changed")
    await fixture.peer.push(
      .event(
        .object([
          "method": .string("remoteControl/status/changed"), "emittedAtMs": .bool(true),
          "params": .object(["status": .string("disabled")]),
        ])))
    await #expect(throws: CodexClientError.malformedFrame) { try await fixture.client.nextEvent() }
    _ = try await fixture.client.close()
  }

  @Test func terminalBeforeStartResponseIsPreservedAndIDsRemainSeparate() async throws {
    let fixture = try ClientFixture(turnFrames: [
      .event(ClientFixture.terminal()), .result(ClientFixture.turn()),
    ])
    try await fixture.client.initialize()
    let upstream = try await fixture.client.start(fixture.submission())
    #expect(upstream == ClientFixture.upstream)
    let event = try await fixture.client.nextEvent()
    #expect(event.method == "turn/completed")
    #expect(event.requestID == ClientFixture.requestID)
    #expect(event.kind == .terminal(CodexTurnSnapshot(upstream: upstream, status: .completed)))
    let sent = await fixture.peer.sent
    #expect(sent.compactMap { $0.object?["id"]?.integer } == [1, 2, 3])
    let params = try #require(sent.last?.object?["params"]?.object)
    #expect(params["cwd"] == .string(ClientFixture.directory.path))
    #expect(params["approvalPolicy"] == .string("on-request"))
    #expect(params["approvalsReviewer"] == .string("user"))
    #expect(
      params["sandboxPolicy"]
        == .object(["type": .string("readOnly"), "networkAccess": .bool(false)]))
    #expect(params["input"]?.array?.first?.object?["text"] == .string(" Exact fixture text.\n"))
    #expect(params["config"] == nil)
    _ = try await fixture.client.close()
  }

  @Test func effectivePermissionsAndThreadDirectoryMustMatch() async throws {
    var variants: [CodexJSON] = []
    for (field, value) in [
      ("approvalPolicy", CodexJSON.string("never")),
      ("approvalsReviewer", .string("auto_review")),
      ("sandbox", .object(["type": .string("dangerFullAccess")])),
      ("sandbox", .object(["type": .string("readOnly"), "networkAccess": .bool(true)])),
      ("cwd", .string("/other")),
    ] {
      var object = ClientFixture.thread().object!
      object[field] = value
      variants.append(.object(object))
    }
    for thread in variants {
      let fixture = try ClientFixture(thread: thread)
      try await fixture.client.initialize()
      await #expect(throws: CodexClientError.permissionMismatch) {
        try await fixture.client.start(fixture.submission())
      }
      #expect(await fixture.peer.sent.count == 3)
      _ = try await fixture.client.close()
    }
  }

  @Test func claimedDirectoryCannotBeOverriddenByARequest() async throws {
    let fixture = try ClientFixture()
    try await fixture.client.initialize()
    let wrong = AuthorizedSubmission(
      request: try fixture.submission().request, workingDirectory: URL(fileURLWithPath: "/other"))
    await #expect(throws: CodexClientError.permissionMismatch) {
      try await fixture.client.start(wrong)
    }
    #expect(await fixture.peer.sent.count == 2)
    _ = try await fixture.client.close()
  }

  @Test func rpcErrorRetainsOnlyCodeAndMalformedOrUnrelatedResponsesFailClosed() async throws {
    let errorFixture = try ClientFixture(threadFrames: [.error(-32600)])
    try await errorFixture.client.initialize()
    await #expect(throws: CodexClientError.rpc(code: -32600)) {
      try await errorFixture.client.start(errorFixture.submission())
    }
    _ = try await errorFixture.client.close()
    for frame in [
      CodexJSON.object(["id": .integer(99), "result": .object([:])]),
      .object(["id": .bool(true), "result": .object([:])]),
      .object(["id": .integer(2), "result": .object([:]), "error": .object([:])]),
      .object(["id": .integer(2), "result": .null]),
    ] {
      let fixture = try ClientFixture(threadFrames: [.event(frame)])
      try await fixture.client.initialize()
      await #expect(throws: (any Error).self) {
        try await fixture.client.start(fixture.submission())
      }
      _ = try await fixture.client.close()
    }
  }

  @Test func approvalRetainsExactMenuAndActionAndOnlyAnswersOnce() async throws {
    let fixture = try ClientFixture()
    try await fixture.start()
    let approval = try await fixture.approval()
    #expect(approval.availableDecisions == ClientFixture.decisions)
    #expect(approval.command == "fixed-command")
    #expect(approval.payload == ClientFixture.approval().object?["params"])
    #expect(approval.upstream == ClientFixture.upstream)
    try await fixture.client.respondApproval(approval, decision: .accept)
    await #expect(throws: CodexClientError.staleApproval) {
      try await fixture.client.respondApproval(approval, decision: .accept)
    }
    let response = await fixture.peer.sent.last
    #expect(
      response
        == .object([
          "id": .string("approval-native"), "result": .object(["decision": .string("accept")]),
        ]))
    _ = try await fixture.client.close()
  }

  @Test func unavailableDecisionAndMutatedApprovalNeverReachTransport() async throws {
    let fixture = try ClientFixture()
    try await fixture.start()
    let approval = try await fixture.approval(decisions: [.string("cancel")])
    let before = await fixture.peer.sent.count
    await #expect(throws: CodexClientError.unavailableDecision) {
      try await fixture.client.respondApproval(approval, decision: .accept)
    }
    let changed = CodexCommandApproval(
      rpcID: approval.rpcID, upstream: approval.upstream, itemID: approval.itemID,
      command: "changed-action", workingDirectory: approval.workingDirectory,
      reason: approval.reason,
      availableDecisions: approval.availableDecisions, payload: approval.payload)
    await #expect(throws: CodexClientError.staleApproval) {
      try await fixture.client.respondApproval(changed, decision: .cancel)
    }
    #expect(await fixture.peer.sent.count == before)
    try await fixture.client.respondApproval(approval, decision: .cancel)
    _ = try await fixture.client.close()
  }

  @Test func mismatchedApprovalActionOrUnknownServerRequestFailsClosed() async throws {
    let actionFixture = try ClientFixture()
    try await actionFixture.start()
    await actionFixture.peer.push(.event(ClientFixture.itemStarted()))
    _ = try await actionFixture.client.nextEvent()
    await actionFixture.peer.push(.event(ClientFixture.approval(command: "different-command")))
    await #expect(throws: CodexClientError.unsupportedMethod) {
      try await actionFixture.client.nextEvent()
    }
    _ = try await actionFixture.client.close()
    let unknown = try ClientFixture()
    try await unknown.start()
    await unknown.peer.push(
      .event(
        .object([
          "id": .integer(400), "method": .string("item/permissions/requestApproval"),
          "params": .object([:]),
        ])))
    await #expect(throws: CodexClientError.unsupportedMethod) {
      try await unknown.client.nextEvent()
    }
    #expect(await unknown.peer.sent.count == 4)
    _ = try await unknown.client.close()
  }

  @Test func interruptCanRunWhileEventsWaitAndAckIsNotTerminal() async throws {
    let fixture = try ClientFixture(extra: [
      ClientStep(method: "turn/interrupt", frames: [.result(.object([:]))])
    ])
    try await fixture.start()
    let waiting = Task { try await fixture.client.nextEvent() }
    try await fixture.client.interrupt(ClientFixture.upstream)
    await fixture.peer.push(.event(ClientFixture.terminal(status: "interrupted")))
    let event = try await waiting.value
    #expect(
      event.kind
        == .terminal(CodexTurnSnapshot(upstream: ClientFixture.upstream, status: .interrupted)))
    await #expect(throws: CodexClientError.invalidTransition) {
      try await fixture.client.interrupt(ClientFixture.upstream)
    }
    _ = try await fixture.client.close()
  }

  @Test func terminalInvalidatesApprovalAndDuplicateTerminalIsRejected() async throws {
    let fixture = try ClientFixture()
    try await fixture.start()
    let approval = try await fixture.approval()
    await fixture.peer.push(.event(ClientFixture.terminal()))
    _ = try await fixture.client.nextEvent()
    await #expect(throws: CodexClientError.staleApproval) {
      try await fixture.client.respondApproval(approval, decision: .accept)
    }
    await fixture.peer.push(.event(ClientFixture.terminal()))
    await #expect(throws: CodexClientError.invalidTransition) {
      try await fixture.client.nextEvent()
    }
    _ = try await fixture.client.close()
  }

  @Test func nativeResolutionInvalidatesUnansweredApprovalAndCommandResultKeepsExactPayload()
    async throws
  {
    let fixture = try ClientFixture()
    try await fixture.start()
    let approval = try await fixture.approval()
    await fixture.peer.push(
      .event(
        .object([
          "method": .string("serverRequest/resolved"),
          "params": .object([
            "threadId": .string(ClientFixture.threadID.uuidString.lowercased()),
            "requestId": .string("approval-native"),
          ]),
        ])))
    let resolved = try await fixture.client.nextEvent()
    #expect(resolved.kind == .approvalResolved(.string("approval-native")))
    #expect(resolved.turnID == ClientFixture.turnID)
    await #expect(throws: CodexClientError.staleApproval) {
      try await fixture.client.respondApproval(approval, decision: .accept)
    }
    let payload: CodexJSON = .object([
      "threadId": .string(ClientFixture.threadID.uuidString.lowercased()),
      "turnId": .string(ClientFixture.turnID.uuidString.lowercased()),
      "item": .object([
        "id": .string("item-1"), "type": .string("commandExecution"),
        "status": .string("completed"), "exitCode": .integer(0),
      ]),
    ])
    await fixture.peer.push(
      .event(.object(["method": .string("item/completed"), "params": payload])))
    let completed = try await fixture.client.nextEvent()
    #expect(completed.payload == payload)
    #expect(completed.itemID == "item-1")
    #expect(completed.requestID == ClientFixture.requestID)
    _ = try await fixture.client.close()
  }

  @Test func historyUsesMetadataThenExactPagedTurnAndResumeReassertsPermissions() async throws {
    let fixture = try ClientFixture(extra: [
      ClientStep(method: "thread/read", frames: [.result(ClientFixture.thread())]),
      ClientStep(
        method: "thread/turns/list",
        frames: [
          .result(
            .object([
              "data": .array([]), "nextCursor": .string("cursor-1"),
            ]))
        ]),
      ClientStep(
        method: "thread/turns/list",
        frames: [
          .result(
            .object([
              "data": .array([ClientFixture.turn().object!["turn"]!]), "nextCursor": .null,
            ]))
        ]),
    ])
    try await fixture.start()
    let snapshot = try await fixture.client.read(ClientFixture.upstream)
    #expect(snapshot == CodexTurnSnapshot(upstream: ClientFixture.upstream, status: .inProgress))
    let sent = await fixture.peer.sent
    #expect(sent[4].object?["params"]?.object?["includeTurns"] == .bool(false))
    #expect(sent[6].object?["params"]?.object?["cursor"] == .string("cursor-1"))
    _ = try await fixture.client.close()

    let resumed = try ClientFixture(resume: true)
    try await resumed.client.initialize()
    _ = try await resumed.client.start(resumed.submission(thread: ClientFixture.threadID))
    let params = await resumed.peer.sent[2].object?["params"]?.object
    #expect(params?["approvalPolicy"] == .string("on-request"))
    #expect(params?["sandbox"] == .string("read-only"))
    #expect(params?["excludeTurns"] == .bool(true))
    _ = try await resumed.client.close()
  }

  @Test func unknownNotificationsMismatchedIDsAndEOFNeverBecomeCompletion() async throws {
    for frame in [
      CodexJSON.object(["method": .string("new/unknown"), "params": .object([:])]),
      ClientFixture.terminal(thread: UUID()),
      ClientFixture.terminal(turn: UUID()),
    ] {
      let fixture = try ClientFixture()
      try await fixture.start()
      await fixture.peer.push(.event(frame))
      await #expect(throws: (any Error).self) { try await fixture.client.nextEvent() }
      _ = try await fixture.client.close()
    }
    let fixture = try ClientFixture()
    try await fixture.start()
    await fixture.peer.push(.disconnect)
    await #expect(throws: CodexClientError.transportFailure(.unexpectedEOF)) {
      try await fixture.client.nextEvent()
    }
    _ = try await fixture.client.close()
  }

  @Test func eventBufferIsBoundedInsteadOfDroppingAnEarlyTerminal() async throws {
    let fixture = try ClientFixture(
      turnFrames: [
        .event(ClientFixture.terminal()), .event(ClientFixture.terminal()),
        .result(ClientFixture.turn()),
      ], maximumBufferedEvents: 1)
    try await fixture.client.initialize()
    await #expect(throws: CodexClientError.eventLimit) {
      try await fixture.client.start(fixture.submission())
    }
    _ = try await fixture.client.close()
  }
}

private enum ClientFrame: Sendable {
  case result(CodexJSON)
  case error(Int64)
  case event(CodexJSON)
  case disconnect
}

private struct ClientStep: Sendable {
  let method: String
  let frames: [ClientFrame]
}

private actor ClientPeer: CodexRPCTransport {
  var sent: [CodexJSON] = []
  private var steps: [ClientStep]
  private var incoming: [Result<CodexJSON, CodexTransportError>] = []
  private var waiter: CheckedContinuation<CodexJSON, any Error>?

  init(steps: [ClientStep]) { self.steps = steps }

  func send(_ frame: CodexJSON) async throws {
    sent.append(frame)
    guard let method = frame.object?["method"]?.string else { return }
    if method == "initialized" { return }
    guard !steps.isEmpty, steps[0].method == method, let id = frame.object?["id"] else {
      throw CodexTransportError.invalidFrame
    }
    for reply in steps.removeFirst().frames {
      switch reply {
      case .result(let result): enqueue(.success(.object(["id": id, "result": result])))
      case .error(let code):
        enqueue(
          .success(
            .object([
              "id": id,
              "error": .object([
                "code": .integer(code), "message": .string("PRIVATE fixture diagnostic"),
              ]),
            ])))
      case .event(let event): enqueue(.success(event))
      case .disconnect: enqueue(.failure(.unexpectedEOF))
      }
    }
  }

  func receive() async throws -> CodexJSON {
    if !incoming.isEmpty { return try incoming.removeFirst().get() }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }

  func push(_ frame: ClientFrame) {
    switch frame {
    case .event(let event): enqueue(.success(event))
    case .disconnect: enqueue(.failure(.unexpectedEOF))
    default: preconditionFailure("Push only an unsolicited event or EOF")
    }
  }

  func shutdown() async throws -> CodexTransportCleanup {
    waiter?.resume(throwing: CodexTransportError.closed)
    waiter = nil
    return CodexTransportCleanup(
      leaderExitStatus: 0, stdoutEOF: true, stderrEOF: true, groupGone: true, escalated: false,
      stdinBytes: 0, stdoutBytes: 0, stderrBytes: 0, withinLimits: true)
  }

  private func enqueue(_ result: Result<CodexJSON, CodexTransportError>) {
    if let continuation = waiter {
      waiter = nil
      continuation.resume(with: result.mapError { $0 as any Error })
    } else {
      incoming.append(result)
    }
  }
}

private struct ClientFixture {
  static let directory: URL = {
    let canonical = realpath("/tmp", nil)!
    defer { free(canonical) }
    return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
  }()
  static let home = directory
  static let requestID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
  static let threadID = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
  static let turnID = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
  static let upstream = UpstreamTurn(threadID: threadID, turnID: turnID)
  static let decisions: [CodexJSON] = [
    .string("accept"),
    .object([
      "acceptWithExecpolicyAmendment": .object([
        "execpolicy_amendment": .array([.string("fixed-command")])
      ])
    ]),
    .string("cancel"),
  ]
  let peer: ClientPeer
  let client: CodexAppServer
  let workingDirectory: URL

  init(
    initialization: CodexJSON = Self.initialize(), thread: CodexJSON = Self.thread(),
    threadFrames: [ClientFrame]? = nil, turnFrames: [ClientFrame]? = nil, resume: Bool = false,
    extra: [ClientStep] = [], maximumBufferedEvents: Int = 256,
    directoryURL: URL = Self.directory, codexHomeURL: URL = Self.home
  ) throws {
    peer = ClientPeer(
      steps: [
        ClientStep(method: "initialize", frames: [.result(initialization)]),
        ClientStep(
          method: resume ? "thread/resume" : "thread/start",
          frames: threadFrames ?? [.result(thread)]),
        ClientStep(method: "turn/start", frames: turnFrames ?? [.result(Self.turn())]),
      ] + extra)
    workingDirectory = directoryURL
    client = try CodexAppServer(
      transport: peer, workingDirectoryURL: directoryURL, codexHomeURL: codexHomeURL,
      maximumBufferedEvents: maximumBufferedEvents)
  }

  func submission(thread: UUID? = nil) throws -> AuthorizedSubmission {
    AuthorizedSubmission(
      request: try TextSubmission(
        requestID: Self.requestID, hostID: UUID(), projectID: UUID(), threadID: thread,
        text: " Exact fixture text.\n"), workingDirectory: workingDirectory)
  }

  func start() async throws {
    try await client.initialize()
    _ = try await client.start(submission())
  }

  func approval(decisions: [CodexJSON] = Self.decisions) async throws -> CodexCommandApproval {
    await peer.push(.event(Self.itemStarted()))
    _ = try await client.nextEvent()
    await peer.push(.event(Self.approval(decisions: decisions)))
    let event = try await client.nextEvent()
    guard case .approval(let approval) = event.kind else { throw CodexClientError.malformedFrame }
    return approval
  }

  static func initialize(version: String = "0.162.1", home: String = Self.home.path) -> CodexJSON {
    .object([
      "userAgent": .string("codex/\(version) macos"), "codexHome": .string(home),
      "platformFamily": .string("unix"), "platformOs": .string("macos"),
    ])
  }

  static func thread() -> CodexJSON {
    .object([
      "thread": .object([
        "id": .string(threadID.uuidString.lowercased()), "cwd": .string(directory.path),
      ]),
      "cwd": .string(directory.path), "approvalPolicy": .string("on-request"),
      "approvalsReviewer": .string("user"),
      "sandbox": .object(["type": .string("readOnly"), "networkAccess": .bool(false)]),
    ])
  }

  static func turn() -> CodexJSON {
    .object([
      "turn": .object([
        "id": .string(turnID.uuidString.lowercased()), "status": .string("inProgress"),
      ])
    ])
  }

  static func terminal(status: String = "completed", thread: UUID = threadID, turn: UUID = turnID)
    -> CodexJSON
  {
    .object([
      "method": .string("turn/completed"),
      "params": .object([
        "threadId": .string(thread.uuidString.lowercased()),
        "turn": .object(["id": .string(turn.uuidString.lowercased()), "status": .string(status)]),
      ]),
    ])
  }

  static func itemStarted(command: String = "fixed-command") -> CodexJSON {
    .object([
      "method": .string("item/started"),
      "params": .object([
        "threadId": .string(threadID.uuidString.lowercased()),
        "turnId": .string(turnID.uuidString.lowercased()),
        "item": .object([
          "id": .string("item-1"), "type": .string("commandExecution"),
          "command": .string(command), "cwd": .string(directory.path),
        ]),
      ]),
    ])
  }

  static func approval(command: String = "fixed-command", decisions: [CodexJSON] = decisions)
    -> CodexJSON
  {
    .object([
      "id": .string("approval-native"), "method": .string("item/commandExecution/requestApproval"),
      "params": .object([
        "threadId": .string(threadID.uuidString.lowercased()),
        "turnId": .string(turnID.uuidString.lowercased()),
        "itemId": .string("item-1"), "kind": .string("command"), "command": .string(command),
        "cwd": .string(directory.path), "reason": .string("fixed fixture reason"),
        "availableDecisions": .array(decisions), "startedAtMs": .integer(1),
      ]),
    ])
  }
}
