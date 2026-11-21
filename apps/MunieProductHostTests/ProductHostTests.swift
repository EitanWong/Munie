import CryptoKit
import Darwin
import Foundation
import MunieExecutionHost
import MunieRemote
import Testing

@testable import MunieProductHost

struct ProductHostTests {
  @Test func pairingRequiresMacConfirmationAndBindsOneExactCandidate() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    let host = try fixture.host(adapter: ProductAdapter())
    try await fixture.register(host)
    #expect(await host.handle(RemoteRequest(op: .status), credential: nil).error == .unauthorized)
    #expect(
      await host.handle(RemoteRequest(op: .status, text: "unexpected"), credential: nil).error
        == .invalidRequest)
    #expect(
      await host.handle(RemoteRequest(op: .status, protocolVersion: 2), credential: nil).error
        == .unsupportedVersion)
    let invite = try await host.startPairing(endpoint: URL(string: "https://test.example")!)
    let id = UUID()
    let secret = Data(repeating: 9, count: 32).base64EncodedString()
    let pair = RemoteRequest(
      op: .pair, invitation: invite.secret, pairingID: id, pairingSecret: secret,
      deviceName: "iPhone")
    #expect(await host.handle(pair, credential: nil).pairingState == .pending)
    #expect(
      await host.handle(RemoteRequest(op: .status), credential: invite.secret).error
        == .unauthorized)
    #expect(
      await host.handle(
        RemoteRequest(
          op: .pair, invitation: invite.secret, pairingID: UUID(), pairingSecret: secret,
          deviceName: "Other"), credential: nil
      ).error == .conflict)
    let candidate = try #require(await host.pendingPairing())
    #expect(candidate.id == id)
    let expected = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(candidate.fingerprint == String(expected.prefix(16)))
    let poll = RemoteRequest(
      op: .pairStatus, invitation: invite.secret, pairingID: id, pairingSecret: secret)
    #expect(await host.handle(poll, credential: nil).credential == nil)
    try await host.approvePairing(projectIDs: [fixture.projectID])
    let approved = await host.handle(poll, credential: nil)
    let token = try #require(approved.credential)
    #expect(approved.pairingState == .approved)
    #expect(await host.handle(poll, credential: nil).credential == token)
    let status = await host.handle(RemoteRequest(op: .status), credential: token)
    #expect(status.status?.projects.map(\.id) == [fixture.projectID])
    #expect(await host.handle(poll, credential: nil).credential == nil)
    let history = try String(
      contentsOf: fixture.state.appending(path: "history.json"), encoding: .utf8)
    #expect(!history.contains(token))
    #expect(!history.contains(invite.secret))
    #expect(!history.contains(secret))
    try await host.close()
  }

  @Test func hostConsumesEventsWithoutPollingAndExactRetryNeverDispatchesAgain() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    let adapter = ProductAdapter()
    let host = try fixture.host(adapter: adapter)
    try await fixture.register(host)
    let token = try await fixture.pair(host)
    let request = RemoteRequest(
      op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "Synthetic task\n")
    let accepted = await host.handle(request, credential: token)
    let task = try #require(accepted.task)
    #expect(task.phase == .running)
    #expect(await host.handle(request, credential: token).task?.id == task.id)
    var changed = request
    changed.text = "changed"
    #expect(await host.handle(changed, credential: token).error == .conflict)
    let upstream = try #require(await adapter.upstream)
    await adapter.enqueue(
      .init(
        method: "item/agentMessage/delta", threadID: upstream.threadID, turnID: upstream.turnID,
        itemID: "reply", kind: .progress, payload: .object(["delta": .string("Hello ")])))
    await adapter.enqueue(
      .init(
        method: "item/agentMessage/delta", threadID: upstream.threadID, turnID: upstream.turnID,
        itemID: "reply", kind: .progress, payload: .object(["delta": .string("world")])))
    await adapter.enqueue(
      .init(
        method: "item/completed", threadID: upstream.threadID, turnID: upstream.turnID,
        itemID: "reply", kind: .progress,
        payload: .object([
          "item": .object(["type": .string("agentMessage"), "text": .string("Hello world")])
        ])))
    await adapter.enqueue(terminal(upstream, .completed))
    let completed = try await waitTask(host, task.id) { $0.phase == .completed }
    #expect(completed.messages.filter { $0.role == .assistant }.map(\.text) == ["Hello world"])
    #expect(await host.handle(request, credential: token).task?.phase == .completed)
    #expect(await adapter.starts == 1)
    let refreshed = await host.handle(
      RemoteRequest(op: .status, taskID: task.id), credential: token)
    #expect(refreshed.status?.tasks.first?.messages == completed.messages)
    try await host.close()
  }

  @Test func approvalIsInformedOneTimeAndCancellationNeedsNativeTerminal() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    let adapter = ProductAdapter()
    let host = try fixture.host(adapter: adapter)
    try await fixture.register(host)
    let token = try await fixture.pair(host)
    let task = try #require(
      await host.handle(
        RemoteRequest(
          op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "Approval test"),
        credential: token
      ).task)
    let upstream = try #require(await adapter.upstream)
    let native = CodexCommandApproval(
      rpcID: .integer(7), upstream: upstream, itemID: "command",
      command: "printf approved > marker", workingDirectory: fixture.project.path,
      reason: "Synthetic marker only", availableDecisions: [.string("accept"), .string("cancel")],
      payload: .object(["command": .string("printf approved > marker")]))
    await adapter.enqueue(
      .init(
        method: "item/commandExecution/requestApproval", threadID: upstream.threadID,
        turnID: upstream.turnID, itemID: "command", kind: .approval(native), payload: native.payload
      ))
    let pending = try await waitTask(host, task.id) { $0.approval != nil }
    let approval = try #require(pending.approval)
    #expect(approval.command == native.command)
    #expect(approval.cwd == fixture.project.path)
    #expect(approval.reason == native.reason)
    let answer = RemoteRequest(
      op: .approve, requestID: task.requestID, taskID: task.id, approvalID: approval.id,
      accept: true)
    #expect(await host.handle(answer, credential: token).error == nil)
    #expect(await host.handle(answer, credential: token).error != nil)
    #expect(await adapter.decisions == [.accept])
    let cancellation = await host.handle(
      RemoteRequest(op: .cancel, requestID: task.requestID, taskID: task.id), credential: token)
    #expect(cancellation.task?.phase == .running)
    #expect(cancellation.task?.cancellationRequested == true)
    #expect(await adapter.interrupts == 1)
    await adapter.enqueue(
      .init(
        method: "serverRequest/resolved", threadID: upstream.threadID, turnID: upstream.turnID,
        itemID: "command", kind: .approvalResolved(.integer(7)), payload: .object([:])))
    await adapter.enqueue(terminal(upstream, .interrupted))
    let cancelled = try await waitTask(host, task.id) { $0.phase == .cancelled }
    #expect(cancelled.cancellationRequested)
    try await host.close()
  }

  @Test func deviceGrantsIsolationRevocationAndPushRegistrationAreLive() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    let adapter = ProductAdapter()
    let host = try fixture.host(adapter: adapter)
    try await fixture.register(host)
    let first = try await fixture.pair(host)
    let second = try await fixture.pair(host, name: "Second iPhone")
    let request = RemoteRequest(
      op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "Private task")
    let task = try #require(await host.handle(request, credential: first).task)
    #expect(
      await host.handle(RemoteRequest(op: .status), credential: second).status?.tasks.isEmpty
        == true)
    #expect(await host.handle(request, credential: second).error == .unauthorized)
    #expect(
      await host.handle(
        RemoteRequest(op: .cancel, requestID: task.requestID, taskID: task.id), credential: second
      ).error == .unauthorized)
    let push = String(repeating: "a", count: 64)
    #expect(
      await host.handle(
        RemoteRequest(op: .registerNotifications, deviceToken: push), credential: second
      ).error == nil)
    #expect(
      await host.handle(
        RemoteRequest(op: .registerNotifications, deviceToken: "invalid"), credential: second
      ).error == .invalidRequest)
    let secondID = try #require(
      await host.devices().first(where: { $0.name == "Second iPhone" })?.id)
    #expect(await host.notificationToken(deviceID: secondID) == push)
    try await host.revokeDevice(id: secondID)
    #expect(
      await host.handle(RemoteRequest(op: .status), credential: second).error == .unauthorized)
    #expect(await host.notificationToken(deviceID: secondID) == nil)
    #expect(
      await host.handle(RemoteRequest(op: .status), credential: first).status?.tasks.first?.id
        == task.id)
    try await host.close()
  }

  @Test func continuationUsesServerOwnedNativeThreadAndPreservesConversation() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    let first = ProductAdapter()
    let second = ProductAdapter()
    let pool = ProductAdapterPool([first, second])
    let host = try ProductHost(
      directoryURL: fixture.state, hostID: fixture.hostID, hostName: "Test Mac", codexReady: true
    ) { _ in try await pool.next() }
    try await fixture.register(host)
    let token = try await fixture.pair(host)
    let initial = RemoteRequest(
      op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "First")
    let task = try #require(await host.handle(initial, credential: token).task)
    let original = try #require(await first.upstream)
    await first.enqueue(terminal(original, .completed))
    _ = try await waitTask(host, task.id) { $0.phase == .completed }
    try await waitClosed(first)
    let next = RemoteRequest(
      op: .submit, requestID: UUID(), taskID: task.id, projectID: fixture.projectID,
      text: "Continue")
    let continued = try #require(await host.handle(next, credential: token).task)
    #expect(continued.id == task.id)
    #expect(continued.requestID == next.requestID)
    #expect(await second.receivedThreadID == original.threadID)
    #expect(continued.messages.filter { $0.role == .user }.map(\.text) == ["First", "Continue"])
    #expect(await host.handle(initial, credential: token).task?.requestID == next.requestID)
    #expect(await first.starts == 1)
    #expect(await second.starts == 1)
    #expect(
      await host.handle(
        RemoteRequest(op: .cancel, requestID: task.requestID, taskID: task.id), credential: token
      ).error == .unauthorized)
    #expect(await second.interrupts == 0)
    try await host.close()
  }

  @Test func restartRecoversKnownTerminalAndResultWithoutNativeResubmission() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    let first = ProductAdapter()
    var host: ProductHost? = try fixture.host(adapter: first)
    try await fixture.register(try #require(host))
    let token = try await fixture.pair(try #require(host))
    let request = RemoteRequest(
      op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "Recover me")
    let task = try #require(await host?.handle(request, credential: token).task)
    let upstream = try #require(await first.upstream)
    try await host?.close()
    host = nil
    try await waitStoreReleased(fixture.state)
    let recovered = ProductAdapter(
      history: CodexTurnSnapshot(upstream: upstream, status: .completed),
      result: "Recovered final reply")
    let reopened = try fixture.host(adapter: recovered)
    let status = await reopened.handle(
      RemoteRequest(op: .status, taskID: task.id), credential: token)
    let restored = try #require(status.status?.tasks.first)
    #expect(restored.id == task.id)
    #expect(restored.phase == .completed)
    #expect(restored.messages.last?.text == "Recovered final reply")
    #expect(await recovered.starts == 0)
    #expect(await recovered.reads == 1)
    #expect(await recovered.resultReads == 1)
    #expect(await reopened.handle(request, credential: token).task?.phase == .completed)
    #expect(await recovered.starts == 0)
    try await reopened.close()
  }

  @Test func missingKnownHistoryStaysReconcilingAndBlocksBlindReplay() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    let first = ProductAdapter()
    var host: ProductHost? = try fixture.host(adapter: first)
    try await fixture.register(try #require(host))
    let token = try await fixture.pair(try #require(host))
    let request = RemoteRequest(
      op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "Uncertain")
    let task = try #require(await host?.handle(request, credential: token).task)
    try await host?.close()
    host = nil
    try await waitStoreReleased(fixture.state)
    let adapter = ProductAdapter()
    let reopened = try fixture.host(adapter: adapter)
    #expect(
      await reopened.handle(RemoteRequest(op: .status), credential: token).status?.tasks.first?
        .phase == .reconciling)
    #expect(await reopened.handle(request, credential: token).task?.id == task.id)
    #expect(
      await reopened.handle(
        RemoteRequest(
          op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "Do not replay"),
        credential: token
      ).error == .busy)
    #expect(await adapter.starts == 0)
    try await reopened.close()
  }

  @Test func failedHistoryWriteStillClosesNativeExecution() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    let adapter = ProductAdapter()
    let host = try fixture.host(adapter: adapter)
    try await fixture.register(host)
    let token = try await fixture.pair(host)
    #expect(
      await host.handle(
        RemoteRequest(
          op: .submit, requestID: UUID(), projectID: fixture.projectID,
          text: "Close despite storage failure"), credential: token
      ).task?.phase == .running)
    let history = fixture.state.appending(path: "history.json")
    try FileManager.default.removeItem(at: history)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
    await #expect(throws: ProductHostCloseFailure.self) { try await host.close() }
    #expect(await adapter.closed)
  }

  @Test(arguments: [false, true])
  func failedCancellationWritePreservesControlAndCanRetry(pendingApproval: Bool) async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    let adapter = ProductAdapter()
    let host = try fixture.host(adapter: adapter)
    try await fixture.register(host)
    let token = try await fixture.pair(host)
    let task = try #require(
      await host.handle(
        RemoteRequest(
          op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "Cancel retry"),
        credential: token
      ).task)
    let upstream = try #require(await adapter.upstream)
    var approvalID: UUID?
    if pendingApproval {
      let native = CodexCommandApproval(
        rpcID: .integer(7), upstream: upstream, itemID: "command",
        command: "printf fixture", workingDirectory: fixture.project.path,
        reason: "Synthetic fixture", availableDecisions: [.string("accept"), .string("cancel")],
        payload: .object(["command": .string("printf fixture")]))
      await adapter.enqueue(
        .init(
          method: "item/commandExecution/requestApproval", threadID: upstream.threadID,
          turnID: upstream.turnID, itemID: "command", kind: .approval(native),
          payload: native.payload))
      approvalID = try await waitTask(host, task.id) { $0.approval != nil }.approval?.id
    }
    let history = fixture.state.appending(path: "history.json")
    let pristine = fixture.state.appending(path: "history-before-fault.json")
    try FileManager.default.moveItem(at: history, to: pristine)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
    let cancel = RemoteRequest(op: .cancel, requestID: task.requestID, taskID: task.id)
    #expect(await host.handle(cancel, credential: token).error == .storage)
    let unchanged = try #require(await host.localStatus().tasks.first)
    #expect(!unchanged.cancellationRequested)
    #expect(unchanged.approval?.id == approvalID)
    #expect(await adapter.interrupts == 0)
    #expect(await adapter.decisions.isEmpty)

    try FileManager.default.removeItem(at: history)
    try FileManager.default.moveItem(at: pristine, to: history)
    let retried = await host.handle(cancel, credential: token)
    #expect(retried.error == nil)
    #expect(retried.task?.phase == .running)
    #expect(retried.task?.cancellationRequested == true)
    #expect(retried.task?.approval == nil)
    #expect(await adapter.interrupts == 1)
    await adapter.enqueue(terminal(upstream, .interrupted))
    let cancelled = try await waitTask(host, task.id) { $0.phase == .cancelled }
    #expect(cancelled.cancellationRequested)
    try await host.close()
  }

  @Test func preLedgerAcceptanceRecoversAsNotStartedAndReleasesCapacity() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    var host: ProductHost? = try fixture.host(adapter: ProductAdapter())
    try await fixture.register(try #require(host))
    let token = try await fixture.pair(try #require(host))
    let deviceID = try #require(await host?.devices().first?.id)
    try await host?.close()
    host = nil
    try await waitStoreReleased(fixture.state)
    let request = RemoteRequest(
      op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "Accepted before ledger")
    let requestID = try #require(request.requestID)
    try seedProductOnlyAcceptance(fixture, request: request, deviceID: deviceID)
    let adapter = ProductAdapter()
    let reopened = try fixture.host(adapter: adapter)
    let recovered = await reopened.handle(
      RemoteRequest(op: .status, taskID: requestID), credential: token)
    #expect(recovered.status?.tasks.first?.phase == .failed)
    #expect(recovered.status?.tasks.first?.messages.last?.text == "host.notStarted")
    #expect(await reopened.handle(request, credential: token).task?.phase == .failed)
    #expect(await adapter.starts == 0)
    let fresh = await reopened.handle(
      RemoteRequest(
        op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "New user action"),
      credential: token)
    #expect(fresh.task?.phase == .running)
    #expect(await adapter.starts == 1)
    try await reopened.close()
  }

  @Test func slowNotificationDeliveryDoesNotBlockNativeReaderOrNextTurn() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    let first = ProductAdapter()
    let second = ProductAdapter()
    let pool = ProductAdapterPool([first, second])
    let notifications = NotificationGate()
    let host = try ProductHost(
      directoryURL: fixture.state, hostID: fixture.hostID, hostName: "Test Mac", codexReady: true,
      adapterFactory: { _ in try await pool.next() },
      notificationSink: { _, task in await notifications.receive(task) })
    try await fixture.register(host)
    let token = try await fixture.pair(host)
    let task = try #require(
      await host.handle(
        RemoteRequest(
          op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "With notice"),
        credential: token
      ).task)
    let upstream = try #require(await first.upstream)
    await first.enqueue(terminal(upstream, .completed))
    _ = try await waitTask(host, task.id) { $0.phase == .completed }
    try await waitClosed(first)
    let next = await host.handle(
      RemoteRequest(
        op: .submit, requestID: UUID(), projectID: fixture.projectID, text: "While notice waits"),
      credential: token)
    #expect(next.task?.phase == .running)
    #expect(await second.starts == 1)
    await notifications.release()
    try await host.close()
  }

  @Test func statusSummariesAndSelectedTranscriptStayWithinTransportBound() async throws {
    let fixture = try ProductFixture()
    defer { fixture.remove() }
    var host: ProductHost? = try fixture.host(adapter: ProductAdapter())
    try await fixture.register(try #require(host))
    let token = try await fixture.pair(try #require(host))
    let deviceID = try #require(await host?.devices().first?.id)
    try await host?.close()
    host = nil
    try await waitStoreReleased(fixture.state)
    let selected = try seedLargeHistory(fixture, deviceID: deviceID)
    let reopened = try fixture.host(adapter: ProductAdapter())
    let summary = await reopened.handle(RemoteRequest(op: .status), credential: token)
    #expect(summary.status?.tasks.count == 1_000)
    #expect(summary.status?.tasks.allSatisfy({ $0.messages.isEmpty }) == true)
    let detail = await reopened.handle(
      RemoteRequest(op: .status, taskID: selected), credential: token)
    #expect(detail.status?.tasks.filter({ !$0.messages.isEmpty }).count == 1)
    #expect(try JSONEncoder().encode(detail).count < 2 * 1_024 * 1_024)
    try await reopened.deleteTask(id: selected)
    #expect(
      await reopened.handle(RemoteRequest(op: .status, taskID: selected), credential: token).error
        == .unauthorized)
    try await reopened.close()
  }

}

private struct ProductFixture {
  let root: URL
  let state: URL
  let project: URL
  let projectID = UUID()
  let hostID = UUID()

  init() throws {
    guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw ProductHostError.invalidStorage
    }
    defer { free(canonical) }
    root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true).appending(
      path: UUID().uuidString)
    state = root.appending(path: "state")
    project = root.appending(path: "project")
    try FileManager.default.createDirectory(
      at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  func host(adapter: ProductAdapter) throws -> ProductHost {
    try ProductHost(directoryURL: state, hostID: hostID, hostName: "Test Mac", codexReady: true) {
      _ in adapter
    }
  }

  func register(_ host: ProductHost) async throws {
    try await host.registerProject(id: projectID, name: "Disposable", directoryURL: project)
  }

  func pair(_ host: ProductHost, name: String = "iPhone") async throws -> String {
    let invite = try await host.startPairing(endpoint: URL(string: "https://test.example")!)
    let id = UUID()
    let secret = Data(UUID().uuidString.utf8.prefix(32)).base64EncodedString()
    let request = RemoteRequest(
      op: .pair, invitation: invite.secret, pairingID: id, pairingSecret: secret, deviceName: name)
    #expect(await host.handle(request, credential: nil).pairingState == .pending)
    try await host.approvePairing(projectIDs: [projectID])
    let token = try #require(
      await host.handle(
        RemoteRequest(
          op: .pairStatus, invitation: invite.secret, pairingID: id, pairingSecret: secret),
        credential: nil
      ).credential)
    #expect(await host.handle(RemoteRequest(op: .status), credential: token).error == nil)
    return token
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor ProductAdapter: CodexExecutionAdapter {
  var starts = 0
  var reads = 0
  var resultReads = 0
  var interrupts = 0
  var decisions: [CodexApprovalDecision] = []
  var upstream: UpstreamTurn?
  var receivedThreadID: UUID?
  var closed = false
  private var queue: [CodexNativeEvent] = []
  private var waiter: CheckedContinuation<CodexNativeEvent, any Error>?
  private let history: CodexTurnSnapshot?
  private let result: String?

  init(history: CodexTurnSnapshot? = nil, result: String? = nil) {
    self.history = history
    self.result = result
  }

  func start(_ submission: AuthorizedSubmission) async throws -> UpstreamTurn {
    guard !closed else { throw ProductHostError.closed }
    starts += 1
    receivedThreadID = submission.request.threadID
    let value = UpstreamTurn(threadID: submission.request.threadID ?? UUID(), turnID: UUID())
    upstream = value
    return value
  }

  func nextEvent() async throws -> CodexNativeEvent {
    if !queue.isEmpty { return queue.removeFirst() }
    if closed { throw ProductHostError.closed }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }

  func enqueue(_ event: CodexNativeEvent) {
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: event)
    } else {
      queue.append(event)
    }
  }

  func interrupt(_ upstream: UpstreamTurn) async throws { interrupts += 1 }
  func read(_ upstream: UpstreamTurn) async throws -> CodexTurnSnapshot? {
    reads += 1
    return history
  }
  func readResult(_ upstream: UpstreamTurn) async throws -> String? {
    resultReads += 1
    return result
  }
  func respondApproval(_ approval: CodexCommandApproval, decision: CodexApprovalDecision)
    async throws
  { decisions.append(decision) }
  func close() async throws -> CodexTransportCleanup {
    closed = true
    waiter?.resume(throwing: ProductHostError.closed)
    waiter = nil
    return CodexTransportCleanup(
      leaderExitStatus: 0, stdoutEOF: true, stderrEOF: true, groupGone: true, escalated: false,
      stdinBytes: 0, stdoutBytes: 0, stderrBytes: 0)
  }
}

private actor ProductAdapterPool {
  var adapters: [ProductAdapter]
  init(_ adapters: [ProductAdapter]) { self.adapters = adapters }
  func next() throws -> ProductAdapter {
    guard !adapters.isEmpty else { throw ProductHostError.unavailable }
    return adapters.removeFirst()
  }
}

private func terminal(_ upstream: UpstreamTurn, _ status: CodexTurnStatus) -> CodexNativeEvent {
  CodexNativeEvent(
    method: "turn/completed", threadID: upstream.threadID, turnID: upstream.turnID,
    kind: .terminal(CodexTurnSnapshot(upstream: upstream, status: status)), payload: .object([:]))
}

private func waitTask(_ host: ProductHost, _ id: UUID, matching: (RemoteTask) -> Bool) async throws
  -> RemoteTask
{
  for _ in 0..<300 {
    if let task = await host.localStatus().tasks.first(where: { $0.id == id }), matching(task) {
      return task
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw ProductHostError.unavailable
}

private func waitClosed(_ adapter: ProductAdapter) async throws {
  for _ in 0..<300 {
    if await adapter.closed { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw ProductHostError.unavailable
}

private func waitStoreReleased(_ directory: URL) async throws {
  let path = directory.appending(path: ".product-owner").path
  for _ in 0..<300 {
    let fd = open(path, O_RDWR | O_CLOEXEC)
    if fd >= 0 {
      let result = flock(fd, LOCK_EX | LOCK_NB)
      close(fd)
      if result == 0 { return }
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw ProductHostError.unavailable
}

private func seedProductOnlyAcceptance(
  _ fixture: ProductFixture, request: RemoteRequest, deviceID: UUID
) throws {
  let persistence = try ProductPersistence(directory: fixture.state)
  var state = try persistence.load(hostID: fixture.hostID)
  let id = try #require(request.requestID)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let digest = SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }
    .joined()
  state.requests.append(ProductRequest(id: id, deviceID: deviceID, taskID: id, digest: digest))
  state.tasks.append(
    ProductTask(
      id: id, deviceID: deviceID, projectID: fixture.projectID, title: "Accepted", requestID: id,
      phase: .accepted, messages: [RemoteMessage(role: .user, text: request.text!)],
      updatedAt: Date()))
  try persistence.save(state)
}

private func seedLargeHistory(_ fixture: ProductFixture, deviceID: UUID) throws -> UUID {
  let persistence = try ProductPersistence(directory: fixture.state)
  var state = try persistence.load(hostID: fixture.hostID)
  let selected = UUID()
  for index in 0..<1_000 {
    let id = index == 0 ? selected : UUID()
    let text = index == 0 ? String(repeating: "\u{0001}", count: 120_000) : "Small reply"
    let requestID = UUID()
    state.requests.append(
      ProductRequest(
        id: requestID, deviceID: deviceID, taskID: id, digest: String(repeating: "a", count: 64)))
    state.tasks.append(
      ProductTask(
        id: id, deviceID: deviceID, projectID: fixture.projectID,
        title: String(repeating: "\u{0002}", count: 64), requestID: requestID, phase: .completed,
        messages: [RemoteMessage(role: .assistant, text: text)], updatedAt: Date()))
  }
  try persistence.save(state)
  return selected
}

private actor NotificationGate {
  var released = false
  var waiter: CheckedContinuation<Void, Never>?
  func receive(_ task: RemoteTask) async {
    if released { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}
