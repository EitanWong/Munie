import CryptoKit
import Darwin
import Foundation
import MunieExecutionHost
import MunieRemote
import Security

public struct ProductPairingCandidate: Sendable {
  public let id: UUID
  public let name: String
  public let fingerprint: String
}

public struct ProductDeviceSummary: Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let enabled: Bool
  public let projectIDs: Set<UUID>
}

public struct ProductHostCloseFailure: Error {
  public let persistenceError: (any Error)?
  public let cleanupError: (any Error)?
}

/// The host owns execution and event consumption. HTTP sessions are replaceable observers.
/// Call close before stopping the service; a disconnected phone never closes native Codex.
public actor ProductHost {
  public typealias AdapterFactory = @Sendable (URL) async throws -> any CodexExecutionAdapter
  public typealias NotificationSink = @Sendable (UUID, RemoteTask) async -> Void

  private struct Pairing {
    let invitationDigest: String
    let expiresAt: Date
    var failures = 0
    var candidate: Candidate?
  }

  private struct Candidate {
    let id: UUID
    let name: String
    let secretDigest: String
    var credential: String?
    var deviceID: UUID?
  }

  private struct Active {
    let token: UUID
    let taskID: UUID
    let requestID: UUID
    let deviceID: UUID
    var session: HostCodexSession?
    var approval: (wire: RemoteApproval, native: CodexCommandApproval)?
    var assistantItems: [String: UUID] = [:]
    var assistantBuffers: [String: String] = [:]
    var controlling = false
  }

  public nonisolated let hostID: UUID
  public nonisolated let hostName: String
  private let persistence: ProductPersistence
  private let ledger: HostSubmissionLedger
  private let adapterFactory: AdapterFactory
  private let notificationSink: NotificationSink?
  private var state: ProductState
  private var pairing: Pairing?
  private var active: Active?
  private var pump: Task<Void, Never>?
  private var approvalTimer: Task<Void, Never>?
  private var notificationWorker: Task<Void, Never>?
  private var notifications: [(UUID, RemoteTask)] = []
  private var recovering = false
  private var closed = false
  public private(set) var lastCleanup: CodexTransportCleanup?
  public private(set) var lastExecutionFailure: String?
  private var codexReady: Bool

  public init(
    directoryURL: URL, hostID: UUID, hostName: String, codexReady: Bool = false,
    adapterFactory: @escaping AdapterFactory, notificationSink: NotificationSink? = nil
  ) throws {
    guard !hostName.isEmpty, hostName.utf8.count <= 256 else {
      throw ProductHostError.invalidConfiguration
    }
    let persistence = try ProductPersistence(directory: directoryURL)
    var state = try persistence.load(hostID: hostID)
    // A committed acceptance is not a proof that native dispatch did or did not happen.
    // Pending approvals are memory-only and cannot authorize anything after restart.
    var changed = false
    for index in state.tasks.indices where !state.tasks[index].phase.isTerminal {
      state.tasks[index].phase = .reconciling
      state.tasks[index].updatedAt = Date()
      changed = true
    }
    if changed {
      guard state.revision < UInt64.max else { throw ProductHostError.corruptStorage }
      state.revision += 1
      try persistence.save(state)
    }
    self.hostID = hostID
    self.hostName = hostName
    self.persistence = persistence
    self.state = state
    self.adapterFactory = adapterFactory
    self.notificationSink = notificationSink
    self.codexReady = codexReady
    ledger = try HostSubmissionLedger(
      directoryURL: directoryURL.appending(path: "ledger", directoryHint: .isDirectory),
      hostID: hostID)
  }

  deinit {
    pump?.cancel()
    approvalTimer?.cancel()
    notificationWorker?.cancel()
  }

  public func registerProject(id: UUID, name: String, directoryURL: URL) async throws {
    try requireOpen()
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      name.utf8.count <= 256, directoryURL.isFileURL
    else { throw ProductHostError.invalidConfiguration }
    guard let pointer = realpath(directoryURL.path, nil) else {
      throw ProductHostError.invalidConfiguration
    }
    let canonical = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    free(pointer)
    guard canonical.path == directoryURL.path else {
      throw ProductHostError.invalidConfiguration
    }
    if let prior = state.projects.first(where: { $0.id == id }) {
      guard prior.name == name, prior.directory == canonical else {
        throw ProductHostError.invalidConfiguration
      }
      try await ledger.registerProject(id: id, directoryURL: canonical)
      return
    }
    guard state.projects.count < 100 else { throw ProductHostError.capacityExceeded }
    try await ledger.registerProject(id: id, directoryURL: canonical)
    try requireOpen()
    try update { $0.projects.append(ProductProject(id: id, name: name, directory: canonical)) }
  }

  public func setCodexReady(_ ready: Bool) throws {
    try requireOpen()
    codexReady = ready
    try update { _ in }
  }

  /// The endpoint must already be a user-configured HTTPS route terminating on this Mac.
  public func startPairing(endpoint: URL) throws -> PairingInvitation {
    try requireOpen()
    guard endpoint.scheme == "https", endpoint.host != nil,
      endpoint.user == nil, endpoint.password == nil, endpoint.query == nil,
      endpoint.fragment == nil, endpoint.path.isEmpty || endpoint.path == "/",
      !state.projects.isEmpty, state.devices.count < 100
    else { throw ProductHostError.invalidConfiguration }
    let invitation = PairingInvitation(
      endpoint: endpoint, hostID: hostID, secret: try Self.randomSecret())
    pairing = Pairing(
      invitationDigest: Self.digest(invitation.secret), expiresAt: Date().addingTimeInterval(120))
    return invitation
  }

  public func pendingPairing() -> ProductPairingCandidate? {
    guard let pairing, pairing.expiresAt > Date(), let candidate = pairing.candidate,
      candidate.credential == nil
    else { return nil }
    return ProductPairingCandidate(
      id: candidate.id, name: candidate.name, fingerprint: String(candidate.secretDigest.prefix(16))
    )
  }

  public func approvePairing(projectIDs: Set<UUID>) async throws {
    try requireOpen()
    guard let pairing, pairing.expiresAt > Date(), let candidate = pairing.candidate,
      candidate.credential == nil, !projectIDs.isEmpty,
      projectIDs.isSubset(of: Set(state.projects.map(\.id))), state.devices.count < 100
    else { throw ProductHostError.noPairingCandidate }
    let deviceID = UUID()
    let credential = try Self.randomSecret()
    // The ledger grant is host-local administration; no remote route can call it.
    try await ledger.authorizeDevice(id: deviceID, projects: projectIDs)
    try requireOpen()
    guard self.pairing?.candidate?.id == candidate.id,
      self.pairing?.expiresAt ?? .distantPast > Date(),
      self.pairing?.candidate?.credential == nil
    else {
      try await ledger.revokeDevice(id: deviceID)
      throw ProductHostError.noPairingCandidate
    }
    try update {
      $0.devices.append(
        ProductDevice(
          id: deviceID, name: candidate.name, credentialDigest: Self.digest(credential),
          projects: projectIDs))
    }
    self.pairing?.candidate?.credential = credential
    self.pairing?.candidate?.deviceID = deviceID
  }

  public func rejectPairing() {
    pairing = nil
  }

  public func revokeDevice(id: UUID) async throws {
    try requireOpen()
    guard state.devices.contains(where: { $0.id == id }) else {
      throw ProductHostError.unauthorized
    }
    try update { state in
      if let index = state.devices.firstIndex(where: { $0.id == id }) {
        state.devices[index].enabled = false
      }
    }
    try await ledger.revokeDevice(id: id)
    if pairing?.candidate?.deviceID == id { pairing = nil }
    // Transport shutdown is a safety action, not proof of upstream cancellation.
    if let current = active, current.deviceID == id {
      var persistenceError: (any Error)?
      do { try markReconciling(current.taskID) } catch { persistenceError = error }
      approvalTimer?.cancel()
      active?.approval = nil
      var cleanupError: (any Error)?
      if let session = current.session {
        do { lastCleanup = try await session.close() } catch { cleanupError = error }
      }
      if active?.token == current.token {
        pump?.cancel()
        pump = nil
        active = nil
      }
      if persistenceError != nil || cleanupError != nil {
        throw ProductHostCloseFailure(
          persistenceError: persistenceError, cleanupError: cleanupError)
      }
    }
  }

  public func devices() -> [ProductDeviceSummary] {
    state.devices.map {
      ProductDeviceSummary(id: $0.id, name: $0.name, enabled: $0.enabled, projectIDs: $0.projects)
    }
  }

  /// Local Mac data-management action. Immutable request digests/ledger entries remain so an
  /// old phone retry cannot recreate a deleted conversation or repeat its side effects.
  public func deleteTask(id: UUID) throws {
    try requireOpen()
    guard let task = state.tasks.first(where: { $0.id == id }), task.phase.isTerminal,
      active?.taskID != id
    else { throw ProductHostError.unavailable }
    try update { $0.tasks.removeAll(where: { $0.id == id }) }
  }

  public func notificationToken(deviceID: UUID) -> String? {
    state.devices.first { $0.id == deviceID && $0.enabled }?.notificationToken
  }

  public func localStatus() -> RemoteStatus { status(for: nil, allDetails: true) }

  public func handle(_ request: RemoteRequest, credential: String?) async -> RemoteResponse {
    do {
      try requireOpen()
      guard request.protocolVersion == 1 else { return RemoteResponse(error: .unsupportedVersion) }
      try validate(request)
      switch request.op {
      case .pair, .pairStatus:
        guard credential == nil else { return RemoteResponse(error: .invalidRequest) }
        return try pair(request)
      case .status:
        let device = try authenticate(credential)
        if let detailID = request.taskID {
          guard
            state.tasks.contains(where: {
              $0.id == detailID && $0.deviceID == device.id
                && device.projects.contains($0.projectID)
            })
          else {
            throw RemoteErrorCode.unauthorized
          }
        }
        await recoverIfNeeded(deviceID: device.id)
        let current = try authenticate(credential)
        return RemoteResponse(status: status(for: current, detailID: request.taskID))
      case .submit:
        return try await submit(request, credential: credential)
      case .approve:
        return try await approve(request, credential: credential)
      case .cancel:
        return try await cancel(request, credential: credential)
      case .registerNotifications:
        let device = try authenticate(credential)
        guard let value = request.deviceToken, value.utf8.count == 64,
          value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return RemoteResponse(error: .invalidRequest) }
        try update { state in
          if let index = state.devices.firstIndex(where: { $0.id == device.id }) {
            state.devices[index].notificationToken = value
          }
        }
        return RemoteResponse(status: status(for: device))
      }
    } catch let error as RemoteErrorCode {
      return RemoteResponse(error: error)
    } catch ProductHostError.closed {
      return RemoteResponse(error: .unavailable)
    } catch {
      lastExecutionFailure = Self.diagnostic(error)
      return RemoteResponse(error: Self.remoteError(error))
    }
  }

  public func close() async throws {
    if closed && active == nil { return }
    closed = true
    pairing = nil
    approvalTimer?.cancel()
    approvalTimer = nil
    notificationWorker?.cancel()
    notificationWorker = nil
    notifications.removeAll()
    let current = active
    var persistenceError: (any Error)?
    if let current, state.tasks.first(where: { $0.id == current.taskID })?.phase.isTerminal == false
    {
      do { try markReconciling(current.taskID) } catch { persistenceError = error }
    }
    pump?.cancel()
    var cleanupError: (any Error)?
    if let session = current?.session {
      do { lastCleanup = try await session.close() } catch { cleanupError = error }
    }
    pump = nil
    if cleanupError == nil { active = nil }
    if persistenceError != nil || cleanupError != nil {
      throw ProductHostCloseFailure(persistenceError: persistenceError, cleanupError: cleanupError)
    }
  }

  private func pair(_ request: RemoteRequest) throws -> RemoteResponse {
    guard let current = pairing, current.expiresAt > Date(), current.failures < 5,
      let invitation = request.invitation,
      Self.same(Self.digest(invitation), current.invitationDigest),
      let id = request.pairingID, let secret = request.pairingSecret, Self.validSecret(secret)
    else {
      pairing?.failures += 1
      return RemoteResponse(pairingState: .expired, error: .expired)
    }
    let digest = Self.digest(secret)
    if let candidate = current.candidate {
      guard candidate.id == id, Self.same(candidate.secretDigest, digest) else {
        pairing?.failures += 1
        return RemoteResponse(error: .conflict)
      }
      if request.op == .pair, request.deviceName != candidate.name {
        return RemoteResponse(error: .conflict)
      }
      if let credential = candidate.credential, let deviceID = candidate.deviceID,
        state.devices.contains(where: { $0.id == deviceID && $0.enabled })
      {
        return RemoteResponse(pairingState: .approved, credential: credential)
      }
      return RemoteResponse(pairingState: .pending)
    }
    guard request.op == .pair, let name = request.deviceName,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128
    else { return RemoteResponse(error: .invalidRequest) }
    pairing?.candidate = Candidate(id: id, name: name, secretDigest: digest)
    return RemoteResponse(pairingState: .pending)
  }

  private func submit(_ request: RemoteRequest, credential: String?) async throws -> RemoteResponse
  {
    let device = try authenticate(credential)
    guard let id = request.requestID, let projectID = request.projectID, let text = request.text,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768,
      device.projects.contains(projectID),
      let project = state.projects.first(where: { $0.id == projectID })
    else { throw RemoteErrorCode.invalidRequest }
    let digest = try Self.requestDigest(request)
    if let prior = state.requests.first(where: { $0.id == id }) {
      guard prior.deviceID == device.id else { throw RemoteErrorCode.unauthorized }
      guard Self.same(prior.digest, digest) else { throw RemoteErrorCode.conflict }
      guard let task = state.tasks.first(where: { $0.id == prior.taskID }) else {
        throw RemoteErrorCode.conflict
      }
      return RemoteResponse(task: wire(task))
    }
    guard codexReady else { throw RemoteErrorCode.unavailable }
    guard active == nil, !recovering, !state.tasks.contains(where: { !$0.phase.isTerminal }) else {
      throw RemoteErrorCode.busy
    }
    guard state.requests.count < 10_000 else { throw RemoteErrorCode.busy }
    let taskID = request.taskID ?? id
    let threadID: UUID?
    if let requested = request.taskID {
      guard let previous = state.tasks.first(where: { $0.id == requested }),
        previous.deviceID == device.id, previous.projectID == projectID
      else { throw RemoteErrorCode.unauthorized }
      guard previous.phase.isTerminal, let nativeThread = previous.threadID else {
        throw RemoteErrorCode.conflict
      }
      guard previous.messages.count < 500,
        try JSONEncoder().encode(previous.messages + [RemoteMessage(role: .user, text: text)]).count
          < 524_288
      else { throw RemoteErrorCode.busy }
      threadID = nativeThread
    } else {
      guard state.tasks.count < 1_000, !state.tasks.contains(where: { $0.id == taskID }) else {
        throw RemoteErrorCode.busy
      }
      threadID = nil
    }
    let token = UUID()
    // Reserve before the first suspension, then commit immutable identity before dispatch.
    active = Active(token: token, taskID: taskID, requestID: id, deviceID: device.id)
    do {
      try update { state in
        state.requests.append(
          ProductRequest(id: id, deviceID: device.id, taskID: taskID, digest: digest))
        let user = RemoteMessage(role: .user, text: text)
        if let index = state.tasks.firstIndex(where: { $0.id == taskID }) {
          state.tasks[index].requestID = id
          state.tasks[index].phase = .accepted
          state.tasks[index].cancellationRequested = false
          state.tasks[index].messages.append(user)
          state.tasks[index].updatedAt = Date()
        } else {
          state.tasks.append(
            ProductTask(
              id: taskID, deviceID: device.id, projectID: projectID,
              title: String(text.prefix(64)), requestID: id, phase: .accepted,
              messages: [user], updatedAt: Date()))
        }
      }
    } catch {
      active = nil
      throw error
    }
    do {
      let adapter = try await adapterFactory(project.directory)
      guard active?.token == token, !closed else {
        _ = try await adapter.close()
        throw ProductHostError.closed
      }
      let session = try HostCodexSession(ledger: ledger, adapter: adapter)
      active?.session = session
      // Revocation between factory creation and dispatch must still deny the task.
      _ = try authenticate(credential)
      let nativeRequest = try TextSubmission(
        requestID: id, hostID: hostID, projectID: projectID, threadID: threadID, text: text)
      let observed = try await session.submit(
        nativeRequest, from: AuthenticatedDevice(id: device.id))
      guard active?.token == token, !closed else { throw ProductHostError.closed }
      try apply(observed, taskID: taskID)
      if observed.submission.phase == .running {
        pump = Task { [weak self] in await self?.receive(token: token) }
      } else {
        lastCleanup = try await session.close()
        active = nil
      }
      let currentDevice = try authenticate(credential)
      guard currentDevice.projects.contains(projectID),
        let task = state.tasks.first(where: { $0.id == taskID })
      else {
        throw RemoteErrorCode.unauthorized
      }
      return RemoteResponse(task: wire(task))
    } catch {
      if active?.token == token {
        let session = active?.session
        var persistenceError: (any Error)?
        if session == nil {
          do {
            try update { state in
              if let index = state.tasks.firstIndex(where: { $0.id == taskID }) {
                state.tasks[index].phase = .failed
                state.tasks[index].messages.append(
                  RemoteMessage(role: .progress, text: "host.unavailable"))
                state.tasks[index].updatedAt = Date()
              }
            }
          } catch { persistenceError = error }
          codexReady = false
        } else {
          do { try markReconciling(taskID) } catch { persistenceError = error }
        }
        var cleanupError: (any Error)?
        if let session {
          do { lastCleanup = try await session.close() } catch { cleanupError = error }
        }
        if active?.token == token { active = nil }
        if persistenceError != nil || cleanupError != nil {
          throw ProductHostCloseFailure(
            persistenceError: persistenceError, cleanupError: cleanupError)
        }
      }
      throw error
    }
  }

  private func approve(_ request: RemoteRequest, credential: String?) async throws -> RemoteResponse
  {
    let device = try authenticate(credential)
    guard let id = request.taskID, let approvalID = request.approvalID, let accept = request.accept,
      let task = state.tasks.first(where: { $0.id == id }), task.deviceID == device.id,
      request.requestID == task.requestID,
      device.projects.contains(task.projectID), var current = active,
      current.taskID == id, current.deviceID == device.id, let session = current.session,
      let approval = current.approval, approval.wire.id == approvalID,
      approval.wire.expiresAt > Date(), !current.controlling
    else { throw RemoteErrorCode.unauthorized }
    current.controlling = true
    current.approval = nil
    active = current
    approvalTimer?.cancel()
    approvalTimer = nil
    do {
      let observed = try await session.respondApproval(
        requestID: current.requestID, approval: approval.native,
        decision: accept ? .accept : .cancel, from: AuthenticatedDevice(id: device.id))
      guard active?.token == current.token else { throw RemoteErrorCode.conflict }
      active?.controlling = false
      try apply(observed, taskID: id)
      _ = try authenticate(credential)
      guard let task = state.tasks.first(where: { $0.id == id }) else {
        throw ProductHostError.corruptStorage
      }
      return RemoteResponse(task: wire(task))
    } catch {
      if active?.token == current.token { active?.controlling = false }
      throw error
    }
  }

  private func cancel(_ request: RemoteRequest, credential: String?) async throws -> RemoteResponse
  {
    let device = try authenticate(credential)
    guard let id = request.taskID, let task = state.tasks.first(where: { $0.id == id }),
      task.deviceID == device.id, device.projects.contains(task.projectID),
      request.requestID == task.requestID
    else { throw RemoteErrorCode.unauthorized }
    if task.phase.isTerminal || task.cancellationRequested {
      return RemoteResponse(task: wire(task))
    }
    guard let current = active, current.taskID == id, current.deviceID == device.id,
      let session = current.session, !current.controlling
    else { throw RemoteErrorCode.unavailable }
    // Retain user intent even if the interrupt response is lost. It is never a terminal.
    // A failed commit must leave both control and any pending approval/timer intact for retry.
    try update { state in
      if let index = state.tasks.firstIndex(where: { $0.id == id }) {
        state.tasks[index].cancellationRequested = true
        state.tasks[index].updatedAt = Date()
      }
    }
    active?.controlling = true
    active?.approval = nil
    approvalTimer?.cancel()
    approvalTimer = nil
    do {
      let observed = try await session.interrupt(
        requestID: current.requestID, from: AuthenticatedDevice(id: device.id))
      guard active?.token == current.token else { throw RemoteErrorCode.conflict }
      active?.controlling = false
      try apply(observed, taskID: id)
      _ = try authenticate(credential)
      guard let task = state.tasks.first(where: { $0.id == id }) else {
        throw ProductHostError.corruptStorage
      }
      return RemoteResponse(task: wire(task))
    } catch {
      if active?.token == current.token {
        active?.controlling = false
        try markReconciling(id)
      }
      throw error
    }
  }

  private func receive(token: UUID) async {
    while !Task.isCancelled, !closed, let current = active, current.token == token,
      let session = current.session
    {
      do {
        let event = try await session.nextEvent(
          requestID: current.requestID, from: AuthenticatedDevice(id: current.deviceID))
        guard active?.token == token, !closed else { return }
        try project(event, taskID: current.taskID)
        if case .terminal = event.kind {
          approvalTimer?.cancel()
          approvalTimer = nil
          active?.approval = nil
          if let task = state.tasks.first(where: { $0.id == current.taskID }) {
            enqueueNotification(deviceID: current.deviceID, task: wire(task))
          }
          lastCleanup = try await session.close()
          if active?.token == token {
            active = nil
            pump = nil
          }
          return
        }
        if case .approval = event.kind,
          let task = state.tasks.first(where: { $0.id == current.taskID })
        {
          enqueueNotification(deviceID: current.deviceID, task: wire(task))
        }
      } catch {
        lastExecutionFailure = Self.diagnostic(error)
        if active?.token != token { return }
        do { try markReconciling(current.taskID) } catch { codexReady = false }
        active?.approval = nil
        approvalTimer?.cancel()
        approvalTimer = nil
        do { lastCleanup = try await session.close() } catch { codexReady = false }
        if active?.token == token {
          active = nil
          pump = nil
        }
        return
      }
    }
  }

  private func project(_ event: CodexNativeEvent, taskID: UUID) throws {
    guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else {
      throw ProductHostError.corruptStorage
    }
    switch event.kind {
    case .approval(let native):
      guard try JSONEncoder().encode(native.command).count <= 65_536,
        try JSONEncoder().encode(native.workingDirectory).count <= 4_096,
        try JSONEncoder().encode(native.reason).count <= 8_192
      else { throw ProductHostError.capacityExceeded }
      let wire = RemoteApproval(
        id: UUID(), command: native.command, cwd: native.workingDirectory,
        reason: native.reason, expiresAt: Date().addingTimeInterval(60))
      active?.approval = (wire, native)
      approvalTimer?.cancel()
      let token = active?.token
      approvalTimer = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
        await self?.expireApproval(token: token, approvalID: wire.id)
      }
      try update { state in state.tasks[index].updatedAt = Date() }
    case .approvalResolved:
      active?.approval = nil
      approvalTimer?.cancel()
      approvalTimer = nil
      try update { state in state.tasks[index].updatedAt = Date() }
    case .terminal(let terminal):
      // Full item/completed text is preferred. Retain a bounded observed delta buffer if the
      // native stream ended the turn without a separate item completion.
      for (itemID, text) in active?.assistantBuffers ?? [:] {
        try appendAssistant(text, itemID: itemID, replace: true, taskIndex: index)
      }
      active?.assistantBuffers = [:]
      let phase: RemotePhase =
        terminal.status == .completed
        ? .completed : terminal.status == .interrupted ? .cancelled : .failed
      try update { state in
        state.tasks[index].phase = phase
        state.tasks[index].threadID = terminal.upstream.threadID
        state.tasks[index].updatedAt = Date()
      }
    case .progress:
      if event.method == "item/agentMessage/delta",
        let delta = event.payload.object?["delta"]?.string,
        let itemID = event.itemID
      {
        let text = (active?.assistantBuffers[itemID] ?? "") + delta
        guard text.utf8.count <= 262_144,
          (active?.assistantBuffers.count ?? 0) < 64 || active?.assistantBuffers[itemID] != nil
        else { throw ProductHostError.capacityExceeded }
        active?.assistantBuffers[itemID] = text
        if state.tasks[index].messages.last?.text != "codex.response.writing" {
          try appendMessage(
            RemoteMessage(role: .progress, text: "codex.response.writing"), taskIndex: index)
        }
      } else if event.method == "item/completed", let item = event.payload.object?["item"]?.object,
        item["type"]?.string == "agentMessage", let text = item["text"]?.string,
        let itemID = event.itemID
      {
        try appendAssistant(text, itemID: itemID, replace: true, taskIndex: index)
        active?.assistantBuffers.removeValue(forKey: itemID)
      } else if let code = Self.progressCode(event) {
        if state.tasks[index].messages.last?.text != code {
          try appendMessage(RemoteMessage(role: .progress, text: code), taskIndex: index)
        }
      }
    }
  }

  private func appendAssistant(_ text: String, itemID: String, replace: Bool, taskIndex: Int) throws
  {
    let (bounded, truncated) = try Self.boundedText(text, maximumEncodedBytes: 262_144)
    if let id = active?.assistantItems[itemID],
      let messageIndex = state.tasks[taskIndex].messages.firstIndex(where: { $0.id == id })
    {
      let previous = state.tasks[taskIndex].messages[messageIndex]
      let result = replace ? bounded : previous.text + bounded
      guard result.utf8.count <= 262_144 else { throw ProductHostError.capacityExceeded }
      var messages = state.tasks[taskIndex].messages
      messages[messageIndex] = RemoteMessage(id: id, role: .assistant, text: result)
      guard try JSONEncoder().encode(messages).count <= 786_432 else {
        throw ProductHostError.capacityExceeded
      }
      try update { state in
        state.tasks[taskIndex].messages[messageIndex] = RemoteMessage(
          id: id, role: .assistant, text: result)
        state.tasks[taskIndex].updatedAt = Date()
      }
    } else {
      let message = RemoteMessage(role: .assistant, text: bounded)
      try appendMessage(message, taskIndex: taskIndex)
      active?.assistantItems[itemID] = message.id
    }
    if truncated {
      try appendMessage(
        RemoteMessage(role: .progress, text: "host.result.truncated"), taskIndex: taskIndex)
    }
  }

  private func appendMessage(_ message: RemoteMessage, taskIndex: Int) throws {
    let task = state.tasks[taskIndex]
    guard task.messages.count < 512,
      try JSONEncoder().encode(task.messages + [message]).count <= 786_432
    else { throw ProductHostError.capacityExceeded }
    try update { state in
      state.tasks[taskIndex].messages.append(message)
      state.tasks[taskIndex].updatedAt = Date()
    }
  }

  private func expireApproval(token: UUID?, approvalID: UUID) async {
    guard let current = active, current.token == token, current.approval?.wire.id == approvalID,
      let session = current.session, !closed
    else { return }
    active?.approval = nil
    do {
      try update { state in
        if let index = state.tasks.firstIndex(where: { $0.id == current.taskID }) {
          state.tasks[index].cancellationRequested = true
          state.tasks[index].messages.append(
            RemoteMessage(role: .progress, text: "approval.expired"))
          state.tasks[index].updatedAt = Date()
        }
      }
      _ = try await session.interrupt(
        requestID: current.requestID, from: AuthenticatedDevice(id: current.deviceID))
    } catch {
      do { try markReconciling(current.taskID) } catch { codexReady = false }
    }
  }

  private func recoverIfNeeded(deviceID: UUID) async {
    guard !recovering, active == nil, !closed else { return }
    recovering = true
    defer { recovering = false }
    let tasks = state.tasks.filter { $0.deviceID == deviceID && $0.phase == .reconciling }
    for task in tasks {
      guard !closed, active == nil,
        let device = state.devices.first(where: { $0.id == deviceID && $0.enabled }),
        device.projects.contains(task.projectID),
        let project = state.projects.first(where: { $0.id == task.projectID })
      else { return }
      var session: HostCodexSession?
      do {
        // No native launch is needed when the ledger never received this acceptance.
        let snapshot: SubmissionSnapshot
        do {
          snapshot = try await ledger.snapshot(
            requestID: task.requestID, from: AuthenticatedDevice(id: deviceID))
        } catch SubmissionError.unknownRequest {
          // The intact ledger is the pre-dispatch authority. This product acceptance never
          // reached it, so no turn/start was authorized; it is safe to release the slot.
          try markNotStarted(task.id)
          continue
        }
        if snapshot.phase == .accepted {
          try markNotStarted(task.id)
          continue
        }
        guard let upstream = snapshot.upstream else { continue }
        let adapter = try await adapterFactory(project.directory)
        let owner = try HostCodexSession(ledger: ledger, adapter: adapter)
        session = owner
        let observed = try await owner.reconcile(
          requestID: task.requestID, from: AuthenticatedDevice(id: deviceID))
        guard !closed, state.devices.first(where: { $0.id == deviceID })?.enabled == true else {
          _ = try await owner.close()
          return
        }
        try apply(observed, taskID: task.id)
        if [.completed, .failed, .cancelled].contains(observed.submission.phase),
          let result = try await adapter.readResult(upstream), !result.isEmpty,
          let index = state.tasks.firstIndex(where: { $0.id == task.id })
        {
          let (bounded, truncated) = try Self.boundedText(result, maximumEncodedBytes: 262_144)
          try update { state in
            let userIndex = state.tasks[index].messages.lastIndex(where: { $0.role == .user }) ?? -1
            state.tasks[index].messages = state.tasks[index].messages.enumerated().filter {
              $0.offset <= userIndex || $0.element.role != .assistant
            }.map(\.element)
            state.tasks[index].messages.append(RemoteMessage(role: .assistant, text: bounded))
            if truncated {
              state.tasks[index].messages.append(
                RemoteMessage(role: .progress, text: "host.result.truncated"))
            }
            guard try JSONEncoder().encode(state.tasks[index].messages).count <= 786_432 else {
              throw ProductHostError.capacityExceeded
            }
            state.tasks[index].updatedAt = Date()
          }
        }
        _ = try await owner.close()
        session = nil
      } catch {
        if let session {
          do { lastCleanup = try await session.close() } catch { codexReady = false }
        }
        // Missing/expired native history is uncertainty, never permission to turn/start again.
      }
    }
  }

  private func apply(_ observed: HostCodexTaskState, taskID: UUID) throws {
    try applySnapshot(
      observed.submission, taskID: taskID, cancellationRequested: observed.cancellationRequested)
  }

  private func applySnapshot(
    _ snapshot: SubmissionSnapshot, taskID: UUID, cancellationRequested: Bool? = nil
  ) throws {
    try update { state in
      guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else {
        throw ProductHostError.corruptStorage
      }
      guard state.tasks[index].requestID == snapshot.requestID else {
        throw ProductHostError.corruptStorage
      }
      let phase: RemotePhase
      switch snapshot.phase {
      case .accepted: phase = .accepted
      case .dispatching, .running: phase = .running
      case .reconciling: phase = .reconciling
      case .completed: phase = .completed
      case .failed: phase = .failed
      case .cancelled: phase = .cancelled
      }
      // A control response can arrive after the host reader committed the terminal.
      if state.tasks[index].phase.isTerminal && !phase.isTerminal { return }
      state.tasks[index].phase = phase
      if let threadID = snapshot.upstream?.threadID { state.tasks[index].threadID = threadID }
      if let cancellationRequested, cancellationRequested {
        state.tasks[index].cancellationRequested = true
      }
      state.tasks[index].updatedAt = Date()
    }
  }

  private func markReconciling(_ taskID: UUID) throws {
    try update { state in
      guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else {
        throw ProductHostError.corruptStorage
      }
      if !state.tasks[index].phase.isTerminal {
        state.tasks[index].phase = .reconciling
        state.tasks[index].updatedAt = Date()
      }
    }
  }

  private func markNotStarted(_ taskID: UUID) throws {
    try update { state in
      guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else {
        throw ProductHostError.corruptStorage
      }
      state.tasks[index].phase = .failed
      state.tasks[index].messages.append(RemoteMessage(role: .progress, text: "host.notStarted"))
      state.tasks[index].updatedAt = Date()
    }
  }

  private func enqueueNotification(deviceID: UUID, task: RemoteTask) {
    guard notificationSink != nil, !closed, notifications.count < 64 else { return }
    notifications.append((deviceID, task))
    guard notificationWorker == nil else { return }
    // Delivery cannot hold the native reader or active slot. The injected transport owns a
    // <=10s request deadline. The finite queue may drop notices; authoritative state remains.
    notificationWorker = Task { [weak self] in await self?.deliverNotifications() }
  }

  private func deliverNotifications() async {
    while !Task.isCancelled, !closed, !notifications.isEmpty {
      let (deviceID, task) = notifications.removeFirst()
      if state.devices.first(where: { $0.id == deviceID })?.enabled == true {
        await notificationSink?(deviceID, task)
      }
    }
    notificationWorker = nil
  }

  private func authenticate(_ credential: String?) throws -> ProductDevice {
    guard let credential, Self.validSecret(credential) else { throw RemoteErrorCode.unauthorized }
    let digest = Self.digest(credential)
    guard let device = state.devices.first(where: { Self.same($0.credentialDigest, digest) }),
      device.enabled
    else {
      throw RemoteErrorCode.unauthorized
    }
    if pairing?.candidate?.deviceID == device.id { pairing = nil }
    return device
  }

  private func status(for device: ProductDevice?, detailID: UUID? = nil, allDetails: Bool = false)
    -> RemoteStatus
  {
    let projects = state.projects.filter { device?.projects.contains($0.id) ?? true }.map {
      RemoteProject(id: $0.id, name: $0.name)
    }
    let tasks = state.tasks.filter {
      guard let device else { return true }
      return $0.deviceID == device.id && device.projects.contains($0.projectID)
    }.map { task in wire(task, includeMessages: allDetails || task.id == detailID) }.sorted {
      $0.updatedAt > $1.updatedAt
    }
    return RemoteStatus(
      hostID: hostID, hostName: hostName, projects: projects, tasks: tasks,
      codexReady: codexReady && !closed, revision: state.revision)
  }

  private func wire(_ task: ProductTask, includeMessages: Bool = true) -> RemoteTask {
    let approval = active?.taskID == task.id ? active?.approval?.wire : nil
    return task.wire(
      approval: approval.flatMap { $0.expiresAt > Date() ? $0 : nil },
      includeMessages: includeMessages)
  }

  private func update(_ body: (inout ProductState) throws -> Void) throws {
    var candidate = state
    try body(&candidate)
    guard candidate.revision < UInt64.max else { throw ProductHostError.capacityExceeded }
    candidate.revision += 1
    try persistence.save(candidate)
    state = candidate
  }

  private func requireOpen() throws {
    if closed { throw ProductHostError.closed }
  }

  private func validate(_ request: RemoteRequest) throws {
    var supplied: Set<String> = []
    if request.requestID != nil { supplied.insert("requestID") }
    if request.taskID != nil { supplied.insert("taskID") }
    if request.projectID != nil { supplied.insert("projectID") }
    if request.text != nil { supplied.insert("text") }
    if request.approvalID != nil { supplied.insert("approvalID") }
    if request.accept != nil { supplied.insert("accept") }
    if request.invitation != nil { supplied.insert("invitation") }
    if request.pairingID != nil { supplied.insert("pairingID") }
    if request.pairingSecret != nil { supplied.insert("pairingSecret") }
    if request.deviceName != nil { supplied.insert("deviceName") }
    if request.deviceToken != nil { supplied.insert("deviceToken") }
    let allowed: Set<String>
    switch request.op {
    case .status: allowed = ["taskID"]
    case .submit: allowed = ["requestID", "taskID", "projectID", "text"]
    case .approve: allowed = ["requestID", "taskID", "approvalID", "accept"]
    case .cancel: allowed = ["requestID", "taskID"]
    case .pair: allowed = ["invitation", "pairingID", "pairingSecret", "deviceName"]
    case .pairStatus: allowed = ["invitation", "pairingID", "pairingSecret"]
    case .registerNotifications: allowed = ["deviceToken"]
    }
    guard supplied.isSubset(of: allowed) else { throw RemoteErrorCode.invalidRequest }
  }

  private static func progressCode(_ event: CodexNativeEvent) -> String? {
    switch event.method {
    case "turn/started": "codex.turn.started"
    case "item/started"
    where event.payload.object?["item"]?.object?["type"]?.string == "commandExecution":
      "codex.command.started"
    case "item/completed"
    where event.payload.object?["item"]?.object?["type"]?.string == "commandExecution":
      "codex.command.completed"
    default: nil
    }
  }

  private static func requestDigest(_ request: RemoteRequest) throws -> String {
    // UTF-8 identity is exact: Swift's canonical Unicode equality is insufficient here.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }
      .joined()
  }

  private static func boundedText(_ text: String, maximumEncodedBytes: Int) throws -> (String, Bool)
  {
    if try JSONEncoder().encode(text).count <= maximumEncodedBytes { return (text, false) }
    var lower = 0
    var upper = min(text.count, maximumEncodedBytes)
    while lower < upper {
      let count = (lower + upper + 1) / 2
      if try JSONEncoder().encode(String(text.prefix(count))).count <= maximumEncodedBytes {
        lower = count
      } else {
        upper = count - 1
      }
    }
    return (String(text.prefix(lower)), true)
  }

  private static func randomSecret() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw ProductHostError.unavailable
    }
    return Data(bytes).base64EncodedString()
  }

  private static func validSecret(_ text: String) -> Bool {
    text.utf8.count == 44 && Data(base64Encoded: text)?.count == 32
  }

  private static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func same(_ left: String, _ right: String) -> Bool {
    let a = Array(left.utf8)
    let b = Array(right.utf8)
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  private static func remoteError(_ error: any Error) -> RemoteErrorCode {
    switch error {
    case SubmissionError.unauthorized, ProductHostError.unauthorized: .unauthorized
    case SubmissionError.requestConflict, SubmissionError.upstreamConflict,
      HostCodexSessionError.staleApproval, HostCodexSessionError.expiredApproval:
      .conflict
    case HostCodexSessionError.busy, HostCodexSessionError.operationInProgress,
      SubmissionError.capacityExceeded, ProductHostError.capacityExceeded:
      .busy
    case SubmissionError.invalidInput, ProductHostError.invalidConfiguration: .invalidRequest
    case ProductHostError.corruptStorage, ProductHostError.invalidStorage,
      ProductHostError.storageFailure, SubmissionError.corruptStore,
      SubmissionError.invalidStorage:
      .storage
    default: .unavailable
    }
  }
  private static func diagnostic(_ error: any Error) -> String {
    if let value = error as? CodexClientError { return "codex: " + String(describing: value) }
    if let value = error as? HostCodexSessionError {
      return "session: " + String(describing: value)
    }
    if let value = error as? SubmissionError { return "ledger: " + String(describing: value) }
    if let value = error as? ProductHostError { return "host: " + String(describing: value) }
    return String(reflecting: type(of: error))
  }

}
