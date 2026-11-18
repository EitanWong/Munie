import Foundation
import Testing

@testable import MunieRemote

@MainActor
struct RemoteModelTests {
  private let project = RemoteProject(id: UUID(), name: "Disposable")
  private let hostID = UUID()

  private func status(tasks: [RemoteTask] = []) -> RemoteStatus {
    RemoteStatus(
      hostID: hostID, hostName: "Synthetic Mac", projects: [project], tasks: tasks, codexReady: true
    )
  }

  @Test func failedSubmissionPersistsAndReconnectDoesNotResubmit() async throws {
    let initial = status()
    let client = ScriptedClient([
      .response(RemoteResponse(status: initial)), .failure(.disconnected),
    ])
    let store = MemoryPendingSubmissionStore()
    let model = RemoteModel(client: client, pendingStore: store)
    await model.refresh()
    model.draft = "Write one marker"
    await model.submit(text: model.draft, projectID: project.id)
    let pending = try #require(await store.load())
    #expect(pending.request.text == "Write one marker")
    #expect(model.connection == .unavailable)
    #expect(model.draft == "Write one marker")
    await client.append(.response(RemoteResponse(status: initial)))
    let restarted = RemoteModel(client: client, pendingStore: store)
    await restarted.restorePending()
    await restarted.refresh()
    #expect(restarted.pendingSubmission == pending)
    #expect(restarted.draft == "Write one marker")
    let requests = await client.requests
    #expect(requests.map(\.op) == [.status, .submit, .status])
    #expect(requests.filter { $0.op == .submit }.count == 1)
  }

  @Test func reconnectFindsAcceptedRequestAndClearsOnlyExactPendingInput() async throws {
    let request = RemoteRequest(
      op: .submit, requestID: UUID(), projectID: project.id, text: "First")
    let task = RemoteTask(
      id: request.requestID!, requestID: request.requestID!, projectID: project.id,
      title: "First", phase: .running)
    let store = MemoryPendingSubmissionStore()
    await store.save(PendingSubmission(request: request))
    let client = ScriptedClient([.response(RemoteResponse(status: status(tasks: [task])))])
    let model = RemoteModel(client: client, pendingStore: store)
    await model.restorePending()
    model.draft = "New unsent edit"
    await model.refresh()
    #expect(model.pendingSubmission == nil)
    #expect(await store.load() == nil)
    #expect(model.draft == "New unsent edit")
    #expect(await client.requests.map(\.op) == [.status])
  }

  @Test func explicitRetryUsesSameIdentityAndTerminalResult() async throws {
    let request = RemoteRequest(
      op: .submit, requestID: UUID(), projectID: project.id, text: "Retry")
    let task = RemoteTask(
      id: request.requestID!, requestID: request.requestID!, projectID: project.id,
      title: "Retry", phase: .completed,
      messages: [RemoteMessage(role: .assistant, text: "Marker exists")])
    let store = MemoryPendingSubmissionStore()
    await store.save(PendingSubmission(request: request))
    let client = ScriptedClient([
      .response(RemoteResponse(status: status())), .response(RemoteResponse(task: task)),
    ])
    let model = RemoteModel(client: client, pendingStore: store)
    await model.restorePending()
    await model.refresh()
    await model.retryPending()
    let requests = await client.requests
    #expect(requests == [RemoteRequest(op: .status), request])
    #expect(model.status?.tasks == [task])
    #expect(model.selectedTaskID == task.id)
    #expect(model.pendingSubmission == nil)
    #expect(model.draft.isEmpty)
    let summary = RemoteTask(
      id: task.id, requestID: task.requestID, projectID: project.id, title: task.title,
      phase: .completed)
    await client.append(.response(RemoteResponse(status: status(tasks: [summary]))))
    await model.refresh()
    #expect(await client.requests.last?.taskID == task.id)
    #expect(model.status?.tasks.first?.messages == task.messages)
  }

  @Test func durableWriteFailureNeverCallsSubmit() async {
    let client = ScriptedClient([.response(RemoteResponse(status: status()))])
    let model = RemoteModel(client: client, pendingStore: FailingStore())
    await model.refresh()
    await model.submit(text: "Must not execute", projectID: project.id)
    #expect(await client.requests.map(\.op) == [.status])
    #expect(model.lastError == .persistence)
    let recoveryClient = ScriptedClient([.response(RemoteResponse(status: status()))])
    let failedRecovery = RemoteModel(
      client: recoveryClient, pendingStore: FailingStore(loadFails: true))
    await failedRecovery.restorePending()
    await failedRecovery.refresh()
    await failedRecovery.submit(text: "Cannot overwrite unresolved recovery", projectID: project.id)
    #expect(await recoveryClient.requests.map(\.op) == [.status])
    #expect(failedRecovery.lastError == .persistence)
  }

  @Test func cancelAcknowledgementDoesNotInventCancelledTerminal() async {
    let id = UUID()
    let running = RemoteTask(
      id: id, requestID: id, projectID: project.id, title: "Wait", phase: .running)
    let acknowledged = RemoteTask(
      id: id, requestID: id, projectID: project.id, title: "Wait", phase: .running,
      cancellationRequested: true)
    let terminal = RemoteTask(
      id: id, requestID: id, projectID: project.id, title: "Wait", phase: .cancelled,
      cancellationRequested: true)
    let client = ScriptedClient([
      .response(RemoteResponse(status: status(tasks: [running]))),
      .response(RemoteResponse(task: acknowledged)),
      .response(RemoteResponse(status: status(tasks: [terminal]))),
    ])
    let model = RemoteModel(client: client)
    await model.refresh()
    await model.cancel(taskID: id)
    #expect(model.status?.tasks.first?.phase == .running)
    #expect(model.status?.tasks.first?.cancellationRequested == true)
    let cancelRequest = await client.requests.last
    #expect(cancelRequest?.requestID == id)
    #expect(cancelRequest?.taskID == id)
    await model.refresh()
    #expect(model.status?.tasks.first?.phase == .cancelled)
  }

  @Test func expiredOrUnboundApprovalCannotSendAcceptance() async {
    let id = UUID()
    let approvalID = UUID()
    let task = RemoteTask(
      id: id, requestID: id, projectID: project.id, title: "Approval", phase: .running,
      approval: RemoteApproval(
        id: approvalID, command: "echo marker", cwd: "/fixture", expiresAt: .distantPast))
    let client = ScriptedClient([.response(RemoteResponse(status: status(tasks: [task])))])
    let model = RemoteModel(client: client)
    await model.refresh()
    await model.respondApproval(taskID: id, approvalID: approvalID, accept: true)
    await model.respondApproval(taskID: id, approvalID: UUID(), accept: true)
    #expect(await client.requests.map(\.op) == [.status])
    #expect(model.lastError == .remote(.expired))
  }

  @Test func continuationUsesConversationIdentityAndNewRequest() async throws {
    let id = UUID()
    let task = RemoteTask(
      id: id, requestID: UUID(), projectID: project.id, title: "Task", phase: .completed)
    let client = ScriptedClient([
      .response(RemoteResponse(status: status(tasks: [task]))), .failure(.disconnected),
    ])
    let model = RemoteModel(client: client)
    await model.refresh()
    await model.submit(text: "Continue", projectID: project.id, taskID: id)
    let request = try #require(await client.requests.last)
    #expect(request.op == .submit)
    #expect(request.taskID == id)
    #expect(request.requestID != task.requestID)
    #expect(request.projectID == project.id)
  }

  @Test func unreadableSelectionFallsBackOnceWithoutMaskingDeviceRevocation() async {
    let missing = UUID()
    let client = ScriptedClient([
      .response(RemoteResponse(error: .unauthorized)),
      .response(RemoteResponse(status: status())),
      .failure(.unauthorized), .failure(.unauthorized),
    ])
    let model = RemoteModel(client: client)
    await model.selectTask(missing)
    #expect(model.connection == .connected)
    #expect(model.selectedTaskID == nil)
    #expect(
      await client.requests == [
        RemoteRequest(op: .status, taskID: missing), RemoteRequest(op: .status),
      ])
    await model.selectTask(missing)
    #expect(model.connection == .unauthorized)
    #expect(model.selectedTaskID == missing)
    #expect(await client.requests.count == 4)
  }

  @Test func hostIdentityCannotChangeInsideEstablishedConnection() async {
    let wrongHost = RemoteStatus(
      hostID: UUID(), hostName: "Other", projects: [project], tasks: [], codexReady: true)
    let client = ScriptedClient([
      .response(RemoteResponse(status: status())), .response(RemoteResponse(status: wrongHost)),
    ])
    let model = RemoteModel(client: client)
    await model.refresh()
    await model.refresh()
    #expect(model.status?.hostID == hostID)
    #expect(model.lastError == .invalidResponse)
    #expect(model.connection == .unavailable)
    await model.submit(text: "Must refresh first", projectID: project.id)
    #expect(await client.requests.count == 2)
  }

  @Test func selectionDuringBusyRefreshReadsLatestTranscriptWithoutPolling() async {
    let id = UUID()
    let requestID = UUID()
    let summary = RemoteTask(
      id: id, requestID: requestID, projectID: project.id, title: "Finished", phase: .completed)
    let detailed = RemoteTask(
      id: id, requestID: requestID, projectID: project.id, title: "Finished", phase: .completed,
      messages: [RemoteMessage(role: .assistant, text: "Authoritative result")])
    let client = SuspendedStatusClient(
      initial: status(tasks: [summary]), detail: status(tasks: [detailed]))
    let started = client.started
    var firstRequest = started.makeAsyncIterator()
    let model = RemoteModel(client: client)
    let refresh = Task { await model.refresh() }
    #expect(await firstRequest.next() == RemoteRequest(op: .status))
    await model.selectTask(id)
    #expect(model.selectedTaskID == id)
    await client.releaseInitial()
    await refresh.value

    // No polling or manual refresh: completing the in-flight read must hydrate the new selection.
    let detailRequest = await withTaskGroup(of: RemoteRequest?.self) { group in
      group.addTask {
        for await request in started { return request }
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return nil
      }
      let request = await group.next() ?? nil
      group.cancelAll()
      return request
    }
    #expect(detailRequest == RemoteRequest(op: .status, taskID: id))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.isBusy && ContinuousClock.now < deadline { await Task.yield() }
    #expect(!model.isBusy)
    #expect(model.status?.tasks.first?.messages == detailed.messages)
    #expect(await client.requests.map(\.op) == [.status, .status])
  }
}

private actor SuspendedStatusClient: RemoteClient {
  let started: AsyncStream<RemoteRequest>
  private let events: AsyncStream<RemoteRequest>.Continuation
  private let initial: RemoteStatus
  private let detail: RemoteStatus
  private var initialResponse: CheckedContinuation<RemoteResponse, Never>?
  private(set) var requests: [RemoteRequest] = []

  init(initial: RemoteStatus, detail: RemoteStatus) {
    (started, events) = AsyncStream.makeStream()
    self.initial = initial
    self.detail = detail
  }

  func call(_ request: RemoteRequest) async -> RemoteResponse {
    requests.append(request)
    events.yield(request)
    if requests.count == 1 {
      return await withCheckedContinuation { initialResponse = $0 }
    }
    return RemoteResponse(status: detail)
  }

  func releaseInitial() {
    initialResponse?.resume(returning: RemoteResponse(status: initial))
    initialResponse = nil
  }
}

private actor ScriptedClient: RemoteClient {
  enum Result: Sendable {
    case response(RemoteResponse)
    case failure(RemoteClientError)
  }
  private var results: [Result]
  private(set) var requests: [RemoteRequest] = []
  init(_ results: [Result]) { self.results = results }
  func append(_ result: Result) { results.append(result) }
  func call(_ request: RemoteRequest) throws -> RemoteResponse {
    requests.append(request)
    guard !results.isEmpty else { throw RemoteClientError.invalidResponse }
    switch results.removeFirst() {
    case .response(let value): return value
    case .failure(let error): throw error
    }
  }
}

private actor FailingStore: PendingSubmissionStore {
  private let loadFails: Bool
  init(loadFails: Bool = false) { self.loadFails = loadFails }
  func load() throws -> PendingSubmission? {
    if loadFails { throw RemoteClientError.persistence }
    return nil
  }
  func save(_ pending: PendingSubmission?) throws { throw RemoteClientError.persistence }
}
