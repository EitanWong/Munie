import CryptoKit
import Foundation

/// Trusted authentication output. Research callers seed it locally or derive it from verified
/// loopback TLS identity; production enrollment and authentication remain unimplemented.
public struct AuthenticatedDevice: Sendable {
  public let id: UUID

  public init(id: UUID) { self.id = id }
}

public struct TextSubmission: Sendable {
  public let requestID: UUID
  public let hostID: UUID
  public let projectID: UUID
  public let threadID: UUID?
  public let text: String

  public init(
    requestID: UUID, hostID: UUID, projectID: UUID, threadID: UUID? = nil, text: String
  ) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 32_768
    else { throw SubmissionError.invalidInput }
    self.requestID = requestID
    self.hostID = hostID
    self.projectID = projectID
    self.threadID = threadID
    self.text = text
  }

  var payloadDigest: String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// This is the host submission phase, not a complete mobile task or Codex event model.
public enum SubmissionPhase: String, Codable, Sendable {
  case accepted, dispatching, running, reconciling, completed, failed, cancelled
}

public struct UpstreamTurn: Codable, Equatable, Sendable {
  public let threadID: UUID
  public let turnID: UUID

  public init(threadID: UUID, turnID: UUID) {
    self.threadID = threadID
    self.turnID = turnID
  }
}

/// Immutable request identity deliberately excludes plaintext and credentials.
struct SubmissionIdentity: Codable, Equatable, Sendable {
  let requestID: UUID
  let deviceID: UUID
  let hostID: UUID
  let projectID: UUID
  let threadID: UUID?
  let payloadDigest: String
  let harnessID: String
  let operation: String
}

public struct SubmissionSnapshot: Codable, Equatable, Sendable {
  public let requestID: UUID
  public let phase: SubmissionPhase
  public let upstream: UpstreamTurn?
}

/// A local dispatch claim, issued once after durable state transition and authorization.
/// It is not a network token and does not promise exactly-once upstream execution.
public struct AuthorizedSubmission: Sendable {
  public let request: TextSubmission
  public let workingDirectory: URL
}

public enum DispatchClaim: Sendable {
  case send(AuthorizedSubmission)
  case existing(SubmissionSnapshot)
}

public enum SubmissionError: Error, Equatable {
  case invalidInput
  case unauthorized
  case projectChanged
  case requestConflict
  case unknownRequest
  case invalidTransition
  case upstreamConflict
  case capacityExceeded
  case invalidStorage
  case storeBusy
  case unsupportedSchema
  case corruptStore
  case storageFailure(code: Int32)
}
