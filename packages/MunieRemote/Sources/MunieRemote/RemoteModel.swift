import Foundation
import Observation

public enum RemoteConnectionState: String, Sendable {
  case disconnected, connecting, connected, unavailable, unauthorized
}

/// The app owns foreground refresh scheduling. This model never polls or resends in the background.
@MainActor
@Observable
public final class RemoteModel {
  public private(set) var status: RemoteStatus?
  public private(set) var connection: RemoteConnectionState = .disconnected
  public private(set) var isBusy = false
  public private(set) var lastError: RemoteClientError?
  public private(set) var pendingSubmission: PendingSubmission?
  public private(set) var selectedTaskID: UUID?
  public var draft = ""

  @ObservationIgnored private var client: (any RemoteClient)?
  @ObservationIgnored private let pendingStore: any PendingSubmissionStore
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var boundEndpoint: URL?
  @ObservationIgnored private var expectedHostID: UUID?
  @ObservationIgnored private var selectionRefreshPending = false
  public private(set) var hasUnresolvedRecovery = false

  public init(pendingStore: any PendingSubmissionStore = MemoryPendingSubmissionStore()) {
    self.pendingStore = pendingStore
  }

  public init(
    client: any RemoteClient,
    pendingStore: any PendingSubmissionStore = MemoryPendingSubmissionStore()
  ) {
    self.client = client
    self.pendingStore = pendingStore
  }

  public func configure(endpoint: URL, credential: String, expectedHostID: UUID? = nil) throws {
    let client = try RemoteHTTPClient(endpoint: endpoint, credential: credential)
    self.client = client
    self.expectedHostID = expectedHostID
    boundEndpoint = try RemoteHTTPClient.validatedEndpoint(endpoint)
    generation = UUID()
    status = nil
    selectedTaskID = nil
    connection = .disconnected
    lastError = nil
    isBusy = false
    selectionRefreshPending = false
  }

  public func disconnect() {
    generation = UUID()
    client = nil
    status = nil
    selectedTaskID = nil
    isBusy = false
    selectionRefreshPending = false
    connection = .disconnected
  }

  public func restorePending() async {
    let token = generation
    do {
      let restored = try await pendingStore.load()
      guard token == generation else { return }
      pendingSubmission = restored
      hasUnresolvedRecovery = false
      if draft.isEmpty { draft = restored?.request.text ?? "" }
    } catch {
      guard token == generation else { return }
      hasUnresolvedRecovery = true
      lastError = .persistence
    }
  }

  /// A reconnect only reads authoritative state. It never submits a pending request.
  public func selectTask(_ id: UUID?) async {
    let changed = selectedTaskID != id
    selectedTaskID = id
    if isBusy {
      if changed { selectionRefreshPending = true }
      return
    }
    await refresh()
  }

  public func refresh(taskID: UUID? = nil) async {
    if let taskID { selectedTaskID = taskID }
    guard !isBusy else { return }
    guard let client else {
      lastError = .unconfigured
      return
    }
    isBusy = true
    let token = generation
    connection = .connecting
    defer { finishRequest(generation: token) }
    do {
      let detailID = selectedTaskID
      let response: RemoteResponse
      var usedFallback = false
      do {
        let selected = try await client.call(RemoteRequest(op: .status, taskID: detailID))
        if let error = selected.error { throw RemoteClientError.remote(error) }
        response = selected
      } catch {
        let failure = error as? RemoteClientError
        guard detailID != nil, failure == .unauthorized || failure == .remote(.unauthorized) else {
          throw error
        }
        guard token == generation else { return }
        // A deleted or no-longer-readable conversation must not masquerade as device revocation.
        // Exactly one read-only fallback checks current authentication without resubmitting work.
        response = try await client.call(RemoteRequest(op: .status))
        usedFallback = true
      }
      guard token == generation else { return }
      if let error = response.error { throw RemoteClientError.remote(error) }
      guard let observed = response.status else { throw RemoteClientError.invalidResponse }
      try validate(observed)
      if usedFallback, selectedTaskID == detailID { selectedTaskID = nil }
      status = retainingTranscripts(observed)
      connection = .connected
      lastError = hasUnresolvedRecovery ? .persistence : nil
      if let pending = pendingSubmission,
        pending.endpoint == boundEndpoint,
        let recoveredTask = observed.tasks.first(where: {
          $0.requestID == pending.request.requestID && $0.projectID == pending.request.projectID
            && (pending.request.taskID == nil || $0.id == pending.request.taskID)
        })
      {
        try await pendingStore.save(nil)
        guard token == generation else { return }
        pendingSubmission = nil
        if selectedTaskID == nil { selectedTaskID = recoveredTask.id }
        if draft == pending.request.text { draft = "" }
      }
    } catch { if token == generation { record(error) } }
  }

  public func submit(text: String, projectID: UUID, taskID: UUID? = nil) async {
    guard !isBusy else {
      lastError = .busy
      return
    }
    guard connection == .connected else {
      lastError = connection == .unauthorized ? .unauthorized : .disconnected
      return
    }
    guard !hasUnresolvedRecovery else {
      lastError = .persistence
      return
    }
    guard pendingSubmission == nil else {
      lastError = .busy
      return
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 32_768 else {
      lastError = .invalidInput
      return
    }
    guard let status, status.projects.contains(where: { $0.id == projectID }), status.codexReady
    else {
      lastError = .unconfigured
      return
    }
    if let taskID {
      guard let task = status.tasks.first(where: { $0.id == taskID }),
        task.projectID == projectID, task.phase.isTerminal
      else {
        lastError = .busy
        return
      }
    }
    let request = RemoteRequest(
      op: .submit, requestID: UUID(), taskID: taskID, projectID: projectID, text: trimmed)
    await send(PendingSubmission(request: request, endpoint: boundEndpoint), persistFirst: true)
  }

  /// Explicit owner action reuses the exact durable request ID and immutable input.
  public func retryPending() async {
    guard !isBusy else {
      lastError = .busy
      return
    }
    guard let pendingSubmission else { return }
    guard connection == .connected else {
      lastError = connection == .unauthorized ? .unauthorized : .disconnected
      return
    }
    guard status?.projects.contains(where: { $0.id == pendingSubmission.request.projectID }) == true
    else {
      lastError = .unauthorized
      return
    }
    guard pendingSubmission.endpoint == boundEndpoint else {
      lastError = .invalidEndpoint
      return
    }
    await send(pendingSubmission, persistFirst: false)
  }

  /// Discarding local recovery input does not cancel or assert anything about a remote task.
  public func discardPending() async {
    guard !isBusy else {
      lastError = .busy
      return
    }
    let token = generation
    do {
      try await pendingStore.save(nil)
      guard token == generation else { return }
      pendingSubmission = nil
      hasUnresolvedRecovery = false
      lastError = nil
    } catch { if token == generation { lastError = .persistence } }
  }

  public func respondApproval(taskID: UUID, approvalID: UUID, accept: Bool) async {
    guard let task = status?.tasks.first(where: { $0.id == taskID }),
      task.approval?.id == approvalID, task.approval!.expiresAt > Date(),
      !task.cancellationRequested
    else {
      lastError = .remote(.expired)
      return
    }
    await control(
      RemoteRequest(
        op: .approve, requestID: task.requestID, taskID: taskID, approvalID: approvalID,
        accept: accept))
  }

  public func cancel(taskID: UUID) async {
    guard let task = status?.tasks.first(where: { $0.id == taskID }), !task.phase.isTerminal else {
      lastError = .invalidInput
      return
    }
    await control(RemoteRequest(op: .cancel, requestID: task.requestID, taskID: taskID))
  }

  private func send(_ pending: PendingSubmission, persistFirst: Bool) async {
    guard let client else {
      lastError = .unconfigured
      return
    }
    isBusy = true
    let token = generation
    defer { finishRequest(generation: token) }
    do {
      if persistFirst {
        try await pendingStore.save(pending)
        guard token == generation else { return }
        pendingSubmission = pending
      }
      let response = try await client.call(pending.request)
      guard token == generation else { return }
      if let error = response.error { throw RemoteClientError.remote(error) }
      guard let task = response.task, task.requestID == pending.request.requestID,
        task.projectID == pending.request.projectID,
        pending.request.taskID == nil || task.id == pending.request.taskID
      else { throw RemoteClientError.invalidResponse }
      try merge(response)
      selectedTaskID = task.id
      try await pendingStore.save(nil)
      guard token == generation else { return }
      pendingSubmission = nil
      // Editing during a network request must not erase the newer text.
      if draft.trimmingCharacters(in: .whitespacesAndNewlines) == pending.request.text {
        draft = ""
      }
      connection = .connected
      lastError = nil
    } catch { if token == generation { record(error) } }
  }

  private func control(_ request: RemoteRequest) async {
    guard connection == .connected else {
      lastError = connection == .unauthorized ? .unauthorized : .disconnected
      return
    }
    guard !isBusy else {
      lastError = .busy
      return
    }
    guard let client else {
      lastError = .unconfigured
      return
    }
    isBusy = true
    let token = generation
    defer { finishRequest(generation: token) }
    do {
      let response = try await client.call(request)
      guard token == generation else { return }
      if let error = response.error { throw RemoteClientError.remote(error) }
      guard response.task?.id == request.taskID || response.status != nil else {
        throw RemoteClientError.invalidResponse
      }
      try merge(response)
      // A cancel acknowledgement keeps the host's phase; only its terminal confirms cancellation.
      connection = .connected
      lastError = nil
    } catch { if token == generation { record(error) } }
  }

  private func merge(_ response: RemoteResponse) throws {
    if let observed = response.status {
      try validate(observed)
      status = retainingTranscripts(observed)
    } else if let task = response.task, let previous = status {
      let tasks = previous.tasks.filter { $0.id != task.id } + [task]
      status = RemoteStatus(
        hostID: previous.hostID, hostName: previous.hostName, projects: previous.projects,
        tasks: tasks.sorted { $0.updatedAt > $1.updatedAt }, codexReady: previous.codexReady,
        revision: previous.revision)
    }
  }

  private func finishRequest(generation token: UUID) {
    guard token == generation else { return }
    isBusy = false
    guard selectionRefreshPending else { return }
    selectionRefreshPending = false
    Task { [weak self] in
      guard let self, self.generation == token else { return }
      // Another operation may start before this follow-up gets the actor; retain the read intent.
      guard !self.isBusy else {
        self.selectionRefreshPending = true
        return
      }
      await self.refresh()
    }
  }

  private func retainingTranscripts(_ observed: RemoteStatus) -> RemoteStatus {
    let tasks = observed.tasks.map { task in
      guard task.messages.isEmpty,
        let cached = status?.tasks.first(where: {
          $0.id == task.id && $0.requestID == task.requestID
        }),
        !cached.messages.isEmpty
      else { return task }
      return RemoteTask(
        id: task.id, requestID: task.requestID, projectID: task.projectID, title: task.title,
        phase: task.phase, cancellationRequested: task.cancellationRequested,
        approval: task.approval, messages: cached.messages, updatedAt: task.updatedAt)
    }
    return RemoteStatus(
      hostID: observed.hostID, hostName: observed.hostName, projects: observed.projects,
      tasks: tasks, codexReady: observed.codexReady, revision: observed.revision)
  }

  private func validate(_ observed: RemoteStatus) throws {
    guard observed.projects.count <= 100, observed.tasks.count <= 1_000,
      Set(observed.projects.map(\.id)).count == observed.projects.count,
      Set(observed.tasks.map(\.id)).count == observed.tasks.count,
      observed.tasks.allSatisfy({ task in observed.projects.contains { $0.id == task.projectID } })
    else { throw RemoteClientError.invalidResponse }
    if let expectedHostID {
      guard expectedHostID == observed.hostID else { throw RemoteClientError.invalidResponse }
    }
    if let current = status {
      guard current.hostID == observed.hostID else { throw RemoteClientError.invalidResponse }
    }
  }

  private func record(_ error: any Error) {
    let failure = (error as? RemoteClientError) ?? .persistence
    lastError = failure
    switch failure {
    case .unauthorized, .remote(.unauthorized): connection = .unauthorized
    case .disconnected, .remote(.unavailable): connection = .unavailable
    default:
      if connection == .connecting { connection = .unavailable }
    }
  }
}
