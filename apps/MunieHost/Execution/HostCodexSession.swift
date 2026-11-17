import Foundation

public enum HostCodexSessionError: Error, Equatable, Sendable {
  case invalidConfiguration, closed, busy, noActiveTask, operationInProgress
  case mismatchedEvent, invalidTransition, staleApproval, expiredApproval, unavailableDecision
}

/// Both errors remain structural; callers must not log raw native payloads or request text.
public struct HostCodexRecoveryFailure: Error {
  public let primary: any Error
  public let recovery: any Error
}

/// Cleanup evidence remains available even when durable-state recovery failed.
public struct HostCodexCloseFailure: Error {
  public let persistenceError: (any Error)?
  public let transportError: (any Error)?
  public let cleanup: CodexTransportCleanup?
}

/// Host-only presentation state. Approval context can contain sensitive command/path text.
public struct HostCodexTaskState: Sendable {
  public let submission: SubmissionSnapshot
  public let cancellationRequested: Bool
  public let pendingApproval: CodexCommandApproval?
}

/// One active task per session. This is a local research coordinator, not a mobile RPC surface.
/// Durable identity/claims live in schema 1; pending approvals and cancellation intent do not.
public actor HostCodexSession {
  private enum Stage { case reserving, starting, running, reconciling, finishing }
  private final class Operation {
    let token = UUID()
    var terminalCommitted = false
  }
  private struct Pending {
    let approval: CodexCommandApproval
    let expires: ContinuousClock.Instant
    var answerable = true
  }
  private struct Active {
    let operation = Operation()
    var token: UUID { operation.token }
    let requestID: UUID
    var upstream: UpstreamTurn?
    var directory: String?
    var stage: Stage
    var cancellationRequested = false
    var pending: Pending?
    var receiving = false
    var controlling = false
  }

  private let ledger: HostSubmissionLedger
  private let adapter: any CodexExecutionAdapter
  private let approvalLifetime: Duration
  private let now: @Sendable () -> ContinuousClock.Instant
  private let terminalCommitObserver: (@Sendable () async -> Void)?
  private var active: Active?
  private var closed = false
  private var closing = false
  private var cleanup: CodexTransportCleanup?

  public init(
    ledger: HostSubmissionLedger, adapter: any CodexExecutionAdapter,
    approvalLifetime: Duration = .seconds(60),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
  ) throws {
    try self.init(
      ledger: ledger, adapter: adapter, approvalLifetime: approvalLifetime, now: now,
      terminalCommitObserver: nil)
  }

  /// Internal barrier makes post-commit authorization races reproducible without changing storage.
  init(
    ledger: HostSubmissionLedger, adapter: any CodexExecutionAdapter,
    approvalLifetime: Duration = .seconds(60),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
    terminalCommitObserver: (@Sendable () async -> Void)?
  ) throws {
    guard approvalLifetime > .zero, approvalLifetime <= .seconds(300) else {
      throw HostCodexSessionError.invalidConfiguration
    }
    self.ledger = ledger
    self.adapter = adapter
    self.approvalLifetime = approvalLifetime
    self.now = now
    self.terminalCommitObserver = terminalCommitObserver
  }

  /// A repeated request validates its exact immutable identity and returns durable state only.
  public func submit(_ request: TextSubmission, from device: AuthenticatedDevice) async throws
    -> HostCodexTaskState
  {
    try requireOpen()
    if let current = active {
      guard current.requestID == request.requestID else { throw HostCodexSessionError.busy }
      _ = try await ledger.accept(request, from: device)
      return try await snapshot(requestID: request.requestID, from: device)
    }
    let reservation = Active(requestID: request.requestID, upstream: nil, stage: .reserving)
    active = reservation
    var claimed = false
    do {
      let accepted = try await ledger.accept(request, from: device)
      try requireCurrent(reservation.token)
      guard accepted.phase == .accepted else {
        let previous = try await adopt(accepted, token: reservation.token, from: device)
        return state(previous)
      }
      let claim = try await ledger.claimForDispatch(request, from: device)
      switch claim {
      case .existing(let previous):
        try requireCurrent(reservation.token)
        let adopted = try await adopt(previous, token: reservation.token, from: device)
        return state(adopted)
      case .send(let authorized):
        claimed = true
        try requireCurrent(reservation.token)
        active?.stage = .starting
        active?.directory = authorized.workingDirectory.path
        // Recheck revocation/project identity after the durable claim and before sending.
        _ = try await ledger.snapshot(requestID: request.requestID, from: device)
        try requireCurrent(reservation.token)
        let upstream = try await adapter.start(authorized)
        // Persist a positive response even if close/revocation happened during the RPC.
        try await ledger.observeStarted(requestID: request.requestID, upstream: upstream)
        try requireCurrent(reservation.token)
        active?.upstream = upstream
        active?.stage = .running
        return try await snapshot(requestID: request.requestID, from: device)
      }
    } catch {
      if claimed {
        throw await uncertain(error, requestID: request.requestID, operation: reservation.operation)
      }
      if active?.token == reservation.token, active?.stage == .reserving { active = nil }
      throw error
    }
  }

  public func snapshot(requestID: UUID, from device: AuthenticatedDevice) async throws
    -> HostCodexTaskState
  {
    try requireOpen()
    let snapshot = try await ledger.snapshot(requestID: requestID, from: device)
    try requireOpen()
    return state(snapshot)
  }

  /// A single consumer pumps native events; control calls may interleave while it awaits data.
  public func nextEvent(requestID: UUID, from device: AuthenticatedDevice) async throws
    -> CodexNativeEvent
  {
    try requireOpen()
    guard let current = active, current.requestID == requestID, current.stage == .running,
      let upstream = current.upstream
    else { throw HostCodexSessionError.noActiveTask }
    guard !current.receiving else { throw HostCodexSessionError.operationInProgress }
    active?.receiving = true
    defer { if active?.token == current.token { active?.receiving = false } }
    _ = try await ledger.snapshot(requestID: requestID, from: device)
    try requireCurrent(current.token)
    do {
      let event = try await adapter.nextEvent()
      try requireCurrent(current.token)
      // A request may have been revoked while receive was suspended; do not expose its payload.
      _ = try await ledger.snapshot(requestID: requestID, from: device)
      try requireCurrent(current.token)
      guard event.requestID == nil || event.requestID == requestID,
        event.threadID == nil || event.threadID == upstream.threadID,
        event.turnID == nil || event.turnID == upstream.turnID
      else { throw HostCodexSessionError.mismatchedEvent }
      switch event.kind {
      case .progress: break
      case .approval(let approval):
        guard approval.upstream == upstream, event.threadID == upstream.threadID,
          event.turnID == upstream.turnID, event.itemID == approval.itemID,
          active?.pending == nil, active?.cancellationRequested == false,
          let directory = active?.directory,
          approval.workingDirectory.utf8.elementsEqual(directory.utf8),
          !approval.itemID.isEmpty, !approval.command.isEmpty,
          !approval.availableDecisions.isEmpty, approval.availableDecisions.count <= 16
        else { throw HostCodexSessionError.mismatchedEvent }
        active?.pending = Pending(approval: approval, expires: now().advanced(by: approvalLifetime))
      case .approvalResolved(let rpcID):
        guard let pending = active?.pending, pending.approval.rpcID == rpcID,
          event.threadID == upstream.threadID, event.turnID == upstream.turnID,
          event.itemID == pending.approval.itemID
        else {
          throw HostCodexSessionError.staleApproval
        }
        active?.pending = nil
      case .terminal(let terminal):
        guard terminal.upstream == upstream, terminal.status.isTerminal,
          event.threadID == upstream.threadID, event.turnID == upstream.turnID
        else { throw HostCodexSessionError.mismatchedEvent }
        try await persistTerminal(terminal, requestID: requestID, operation: current.operation)
        // Committing terminal state suspends too; retain the evidence but recheck payload access.
        _ = try await ledger.snapshot(requestID: requestID, from: device)
        try requireOpen()
      }
      return event
    } catch {
      throw await uncertain(error, requestID: requestID, operation: current.operation)
    }
  }

  public func respondApproval(
    requestID: UUID, approval: CodexCommandApproval, decision: CodexApprovalDecision,
    from device: AuthenticatedDevice
  ) async throws -> HostCodexTaskState {
    try requireOpen()
    let durable = try await ledger.snapshot(requestID: requestID, from: device)
    try requireOpen()
    guard let current = active, current.requestID == requestID, current.stage == .running,
      let pending = current.pending, try sameApproval(pending.approval, approval),
      pending.answerable, !current.cancellationRequested, current.upstream == approval.upstream,
      durable.phase == .running, durable.upstream == current.upstream
    else { throw HostCodexSessionError.staleApproval }
    guard !current.controlling else { throw HostCodexSessionError.operationInProgress }
    guard now() < pending.expires else {
      active?.pending?.answerable = false
      throw HostCodexSessionError.expiredApproval
    }
    guard approval.availableDecisions.contains(.string(decision.rawValue)) else {
      throw HostCodexSessionError.unavailableDecision
    }
    active?.controlling = true
    // Keep the native ID for its resolved event, but prevent another answer before awaiting RPC.
    active?.pending?.answerable = false
    defer { if active?.token == current.token { active?.controlling = false } }
    do {
      try await adapter.respondApproval(approval, decision: decision)
      return try await snapshot(requestID: requestID, from: device)
    } catch {
      throw await uncertain(error, requestID: requestID, operation: current.operation)
    }
  }

  /// The acknowledgement changes only local intent. A matching terminal is still required.
  public func interrupt(requestID: UUID, from device: AuthenticatedDevice) async throws
    -> HostCodexTaskState
  {
    try requireOpen()
    let durable = try await ledger.snapshot(requestID: requestID, from: device)
    try requireOpen()
    guard let current = active, current.requestID == requestID, current.stage == .running,
      let upstream = current.upstream, durable.phase == .running, durable.upstream == upstream
    else { throw HostCodexSessionError.noActiveTask }
    guard !current.controlling else { throw HostCodexSessionError.operationInProgress }
    if current.cancellationRequested {
      return try await snapshot(requestID: requestID, from: device)
    }
    active?.controlling = true
    active?.cancellationRequested = true
    active?.pending?.answerable = false
    defer { if active?.token == current.token { active?.controlling = false } }
    do {
      try await adapter.interrupt(upstream)
      return try await snapshot(requestID: requestID, from: device)
    } catch {
      throw await uncertain(error, requestID: requestID, operation: current.operation)
    }
  }

  /// Only positive history for the exact persisted IDs may resolve an uncertain request.
  /// Missing history and in-progress history preserve uncertainty; neither authorizes replay.
  public func reconcile(requestID: UUID, from device: AuthenticatedDevice) async throws
    -> HostCodexTaskState
  {
    try requireOpen()
    if let current = active, current.requestID != requestID { throw HostCodexSessionError.busy }
    if let current = active,
      current.receiving || current.controlling || current.stage == .reserving
        || current.stage == .starting || current.stage == .finishing
    {
      throw HostCodexSessionError.operationInProgress
    }
    let reservation = active ?? Active(requestID: requestID, upstream: nil, stage: .reserving)
    active = reservation
    active?.controlling = true
    defer { if active?.token == reservation.token { active?.controlling = false } }
    var snapshot: SubmissionSnapshot
    do {
      snapshot = try await ledger.snapshot(requestID: requestID, from: device)
      try requireCurrent(reservation.token)
    } catch {
      if reservation.stage == .reserving, active?.token == reservation.token { active = nil }
      throw error
    }
    if snapshot.phase != .reconciling {
      if snapshot.phase == .running, reservation.stage == .running { return state(snapshot) }
      snapshot = try await adopt(snapshot, token: reservation.token, from: device)
      guard snapshot.phase == .reconciling else { return state(snapshot) }
    }
    active?.upstream = snapshot.upstream
    active?.stage = .reconciling
    active?.pending = nil
    guard let upstream = snapshot.upstream else { return state(snapshot) }
    do {
      let observed = try await adapter.read(upstream)
      try requireCurrent(reservation.token)
      let authorized = try await ledger.snapshot(requestID: requestID, from: device)
      try requireCurrent(reservation.token)
      guard let observed else { return state(authorized) }
      guard observed.upstream == upstream else { throw HostCodexSessionError.mismatchedEvent }
      guard observed.status.isTerminal else { return state(authorized) }
      try await persistTerminal(observed, requestID: requestID, operation: reservation.operation)
      return try await self.snapshot(requestID: requestID, from: device)
    } catch {
      throw await uncertain(error, requestID: requestID, operation: reservation.operation)
    }
  }

  /// Closing a transport is not evidence that its task was cancelled.
  public func close() async throws -> CodexTransportCleanup {
    if let cleanup { return cleanup }
    guard !closing else { throw HostCodexSessionError.operationInProgress }
    closing = true
    closed = true
    let current = active
    active?.pending = nil
    var persistenceError: (any Error)?
    if let current, current.stage != .reserving, current.stage != .finishing {
      do { try await ledger.markUncertain(requestID: current.requestID) } catch {
        persistenceError = error
      }
    }
    var transportError: (any Error)?
    do { cleanup = try await adapter.close() } catch { transportError = error }
    closing = false
    if cleanup != nil { active = nil }
    if persistenceError != nil || transportError != nil {
      throw HostCodexCloseFailure(
        persistenceError: persistenceError, transportError: transportError, cleanup: cleanup)
    }
    guard let cleanup else { throw HostCodexSessionError.invalidTransition }
    return cleanup
  }

  private func requireOpen() throws {
    guard !closed else { throw HostCodexSessionError.closed }
  }

  private func requireCurrent(_ token: UUID) throws {
    try requireOpen()
    guard active?.token == token else { throw HostCodexSessionError.noActiveTask }
  }

  private func adopt(
    _ snapshot: SubmissionSnapshot, token: UUID, from device: AuthenticatedDevice
  ) async throws -> SubmissionSnapshot {
    try requireCurrent(token)
    if [.accepted, .completed, .failed, .cancelled].contains(snapshot.phase) {
      active = nil
      return snapshot
    } else {
      active?.upstream = snapshot.upstream
      active?.stage = .reconciling
    }
    // A new session does not own the old native event stream, even within one ledger lifetime.
    // Only this new reservation can move observed running/dispatching state to uncertainty.
    guard snapshot.phase != .reconciling else { return snapshot }
    try await ledger.markUncertain(requestID: snapshot.requestID)
    try requireCurrent(token)
    let adopted = try await ledger.snapshot(requestID: snapshot.requestID, from: device)
    try requireCurrent(token)
    return adopted
  }

  private func state(_ snapshot: SubmissionSnapshot) -> HostCodexTaskState {
    let current = active?.requestID == snapshot.requestID ? active : nil
    return HostCodexTaskState(
      submission: snapshot, cancellationRequested: current?.cancellationRequested ?? false,
      pendingApproval: current?.pending.flatMap {
        snapshot.phase == .running && $0.answerable && now() < $0.expires ? $0.approval : nil
      })
  }

  private func phase(_ status: CodexTurnStatus) -> SubmissionPhase {
    switch status {
    case .completed: .completed
    case .interrupted: .cancelled
    case .failed: .failed
    case .inProgress: .running
    }
  }

  private func sameApproval(_ left: CodexCommandApproval, _ right: CodexCommandApproval) throws
    -> Bool
  {
    let sameID: Bool
    switch (left.rpcID, right.rpcID) {
    case (.integer(let first), .integer(let second)): sameID = first == second
    case (.string(let first), .string(let second)): sameID = first.utf8.elementsEqual(second.utf8)
    default: sameID = false
    }
    let sameReason: Bool
    switch (left.reason, right.reason) {
    case (.none, .none): sameReason = true
    case (.some(let first), .some(let second)): sameReason = first.utf8.elementsEqual(second.utf8)
    default: sameReason = false
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let sameDecisions =
      try encoder.encode(left.availableDecisions) == encoder.encode(right.availableDecisions)
    let samePayload = try encoder.encode(left.payload) == encoder.encode(right.payload)
    return sameID && left.upstream == right.upstream
      && left.itemID.utf8.elementsEqual(right.itemID.utf8)
      && left.command.utf8.elementsEqual(right.command.utf8)
      && left.workingDirectory.utf8.elementsEqual(right.workingDirectory.utf8)
      && sameReason && sameDecisions && samePayload
  }

  private func persistTerminal(
    _ terminal: CodexTurnSnapshot, requestID: UUID, operation: Operation
  ) async throws {
    active?.stage = .finishing
    active?.pending = nil
    do {
      try await ledger.observeTerminal(
        requestID: requestID, upstream: terminal.upstream, phase: phase(terminal.status))
      operation.terminalCommitted = true
      if active?.token == operation.token { active = nil }
      await terminalCommitObserver?()
    } catch {
      if active?.token == operation.token { active?.stage = .reconciling }
      throw error
    }
  }

  private func uncertain(_ primary: any Error, requestID: UUID, operation: Operation) async
    -> any Error
  {
    // A concurrent control RPC cannot regress positive terminal evidence being persisted.
    if operation.terminalCommitted
      || (active?.token == operation.token && active?.stage == .finishing)
    {
      return primary
    }
    if active?.token == operation.token {
      active?.pending = nil
      active?.stage = .reconciling
    }
    do { try await ledger.markUncertain(requestID: requestID) } catch {
      return HostCodexRecoveryFailure(primary: primary, recovery: error)
    }
    return primary
  }
}
