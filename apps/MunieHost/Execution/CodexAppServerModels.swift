import Foundation

/// Native JSON-RPC identity, deliberately distinct from a Munie request or Codex turn ID.
public enum CodexRPCID: Hashable, Sendable {
  case integer(Int64)
  case string(String)

  public static func == (left: Self, right: Self) -> Bool {
    switch (left, right) {
    case (.integer(let first), .integer(let second)): first == second
    case (.string(let first), .string(let second)): first.utf8.elementsEqual(second.utf8)
    default: false
    }
  }

  public func hash(into hasher: inout Hasher) {
    switch self {
    case .integer(let value):
      hasher.combine(0)
      hasher.combine(value)
    case .string(let value):
      hasher.combine(1)
      hasher.combine(Data(value.utf8))
    }
  }
}

public enum CodexClientError: Error, Equatable, Sendable {
  case invalidConfiguration
  case alreadyInitialized
  case notInitialized
  case closed
  case busy
  case malformedFrame
  case responseMismatch
  case unsupportedVersion
  case unsupportedMethod
  case permissionMismatch
  case identityMismatch
  case invalidTransition
  case staleApproval
  case unavailableDecision
  case eventLimit
  case paginationLimit
  case transport
  case transportFailure(CodexTransportError)
  case rpc(code: Int64)
}

public enum CodexTurnStatus: String, Equatable, Sendable {
  case inProgress, completed, interrupted, failed

  public var isTerminal: Bool { self != .inProgress }
}

public struct CodexTurnSnapshot: Equatable, Sendable {
  public let upstream: UpstreamTurn
  public let status: CodexTurnStatus

  public init(upstream: UpstreamTurn, status: CodexTurnStatus) {
    self.upstream = upstream
    self.status = status
  }
}

/// Host-only approval context. It may contain sensitive command/path text; never log it.
/// The coordinator owns authentication rechecks and a bounded lease before answering.
public struct CodexCommandApproval: Equatable, Sendable {
  public let rpcID: CodexRPCID
  public let upstream: UpstreamTurn
  public let itemID: String
  public let command: String
  public let workingDirectory: String
  public let reason: String?
  public let availableDecisions: [CodexJSON]
  public let payload: CodexJSON

  public init(
    rpcID: CodexRPCID, upstream: UpstreamTurn, itemID: String, command: String,
    workingDirectory: String, reason: String?, availableDecisions: [CodexJSON], payload: CodexJSON
  ) {
    self.rpcID = rpcID
    self.upstream = upstream
    self.itemID = itemID
    self.command = command
    self.workingDirectory = workingDirectory
    self.reason = reason
    self.availableDecisions = availableDecisions
    self.payload = payload
  }

  public static func == (left: Self, right: Self) -> Bool {
    let sameReason: Bool
    switch (left.reason, right.reason) {
    case (.none, .none): sameReason = true
    case (.some(let first), .some(let second)): sameReason = first.utf8.elementsEqual(second.utf8)
    default: sameReason = false
    }
    guard left.rpcID == right.rpcID, left.upstream == right.upstream,
      left.itemID.utf8.elementsEqual(right.itemID.utf8),
      left.command.utf8.elementsEqual(right.command.utf8),
      left.workingDirectory.utf8.elementsEqual(right.workingDirectory.utf8), sameReason,
      let firstDecisions = try? CodexJSON.array(left.availableDecisions).encoded(),
      let secondDecisions = try? CodexJSON.array(right.availableDecisions).encoded(),
      let firstPayload = try? left.payload.encoded(),
      let secondPayload = try? right.payload.encoded()
    else { return false }
    return firstDecisions == secondDecisions && firstPayload == secondPayload
  }
}

/// Only explicit one-time decisions are implemented. Session/persistent grants are not aliases.
public enum CodexApprovalDecision: String, Sendable {
  case accept, cancel
}

public struct CodexNativeEvent: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case progress
    case approval(CodexCommandApproval)
    case approvalResolved(CodexRPCID)
    case terminal(CodexTurnSnapshot)
  }

  public let method: String
  public let requestID: UUID?
  public let threadID: UUID?
  public let turnID: UUID?
  public let itemID: String?
  public let kind: Kind
  /// Exact native params, retained only for an authorized host consumer, never diagnostics.
  public let payload: CodexJSON

  public init(
    method: String, requestID: UUID? = nil, threadID: UUID? = nil, turnID: UUID? = nil,
    itemID: String? = nil, kind: Kind, payload: CodexJSON
  ) {
    self.method = method
    self.requestID = requestID
    self.threadID = threadID
    self.turnID = turnID
    self.itemID = itemID
    self.kind = kind
    self.payload = payload
  }
}

/// Codex-specific seam for the durable host coordinator, not a cross-harness abstraction.
public protocol CodexExecutionAdapter: Sendable {
  func start(_ submission: AuthorizedSubmission) async throws -> UpstreamTurn
  func nextEvent() async throws -> CodexNativeEvent
  func interrupt(_ upstream: UpstreamTurn) async throws
  /// nil is an explicitly missing history entry, never evidence of completion.
  func read(_ upstream: UpstreamTurn) async throws -> CodexTurnSnapshot?
  /// Curated final assistant text only; never a raw native history payload.
  func readResult(_ upstream: UpstreamTurn) async throws -> String?
  func respondApproval(_ approval: CodexCommandApproval, decision: CodexApprovalDecision)
    async throws
  func close() async throws -> CodexTransportCleanup
}

extension CodexExecutionAdapter {
  /// Other adapters must explicitly implement persisted result recovery before advertising it.
  public func readResult(_ upstream: UpstreamTurn) async throws -> String? { nil }
}
