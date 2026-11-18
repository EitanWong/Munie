import Foundation

public struct RemoteProject: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String

  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }
}

public enum RemotePhase: String, Codable, Sendable {
  case accepted, running, reconciling, completed, failed, cancelled

  public var isTerminal: Bool { [.completed, .failed, .cancelled].contains(self) }
}

public struct RemoteMessage: Codable, Equatable, Identifiable, Sendable {
  public enum Role: String, Codable, Sendable { case user, assistant, progress }
  public let id: UUID
  public let role: Role
  public let text: String

  public init(id: UUID = UUID(), role: Role, text: String) {
    self.id = id
    self.role = role
    self.text = text
  }
}

public struct RemoteApproval: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let command: String
  public let cwd: String
  public let reason: String?
  public let expiresAt: Date

  public init(id: UUID, command: String, cwd: String, reason: String? = nil, expiresAt: Date) {
    self.id = id
    self.command = command
    self.cwd = cwd
    self.reason = reason
    self.expiresAt = expiresAt
  }
}

/// A conversation ID stays stable across turns; requestID identifies the current submission.
public struct RemoteTask: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let requestID: UUID
  public let projectID: UUID
  public let title: String
  public let phase: RemotePhase
  public let cancellationRequested: Bool
  public let approval: RemoteApproval?
  public let messages: [RemoteMessage]
  public let updatedAt: Date

  public init(
    id: UUID, requestID: UUID, projectID: UUID, title: String, phase: RemotePhase,
    cancellationRequested: Bool = false, approval: RemoteApproval? = nil,
    messages: [RemoteMessage] = [], updatedAt: Date = Date()
  ) {
    self.id = id
    self.requestID = requestID
    self.projectID = projectID
    self.title = title
    self.phase = phase
    self.cancellationRequested = cancellationRequested
    self.approval = approval
    self.messages = messages
    self.updatedAt = updatedAt
  }
}

public struct RemoteStatus: Codable, Equatable, Sendable {
  public let hostID: UUID
  public let hostName: String
  public let projects: [RemoteProject]
  public let tasks: [RemoteTask]
  public let codexReady: Bool
  public let revision: UInt64

  public init(
    hostID: UUID, hostName: String, projects: [RemoteProject], tasks: [RemoteTask],
    codexReady: Bool, revision: UInt64 = 0
  ) {
    self.hostID = hostID
    self.hostName = hostName
    self.projects = projects
    self.tasks = tasks
    self.codexReady = codexReady
    self.revision = revision
  }
}

public enum RemoteOperation: String, Codable, Sendable {
  case status, submit, approve, cancel, pair, pairStatus, registerNotifications
}

/// Fixed business operations only. No arbitrary RPC, host path or shell launch endpoint exists.
public struct RemoteRequest: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var op: RemoteOperation
  public var requestID: UUID?
  public var taskID: UUID?
  public var projectID: UUID?
  public var text: String?
  public var approvalID: UUID?
  public var accept: Bool?
  public var invitation: String?
  public var pairingID: UUID?
  public var pairingSecret: String?
  public var deviceName: String?
  public var deviceToken: String?

  public init(
    op: RemoteOperation, requestID: UUID? = nil, taskID: UUID? = nil, projectID: UUID? = nil,
    text: String? = nil, approvalID: UUID? = nil, accept: Bool? = nil,
    invitation: String? = nil, pairingID: UUID? = nil, pairingSecret: String? = nil,
    deviceName: String? = nil, deviceToken: String? = nil, protocolVersion: Int = 1
  ) {
    self.protocolVersion = protocolVersion
    self.op = op
    self.requestID = requestID
    self.taskID = taskID
    self.projectID = projectID
    self.text = text
    self.approvalID = approvalID
    self.accept = accept
    self.invitation = invitation
    self.pairingID = pairingID
    self.pairingSecret = pairingSecret
    self.deviceName = deviceName
    self.deviceToken = deviceToken
  }
}

public enum RemotePairingState: String, Codable, Sendable { case pending, approved, expired }

public enum RemoteErrorCode: String, Codable, Error, Sendable {
  case invalidRequest, unauthorized, expired, busy, conflict, unavailable, storage
  case unsupportedVersion, internalFailure
}

public struct RemoteResponse: Codable, Equatable, Sendable {
  public let status: RemoteStatus?
  public let task: RemoteTask?
  public let pairingState: RemotePairingState?
  public let credential: String?
  public let error: RemoteErrorCode?

  public init(
    status: RemoteStatus? = nil, task: RemoteTask? = nil,
    pairingState: RemotePairingState? = nil, credential: String? = nil,
    error: RemoteErrorCode? = nil
  ) {
    self.status = status
    self.task = task
    self.pairingState = pairingState
    self.credential = credential
    self.error = error
  }
}

/// This value is a short-lived secret and must not be put into URLs, logs or notifications.
public struct PairingInvitation: Codable, Equatable, Sendable {
  public let endpoint: URL
  public let hostID: UUID
  public let secret: String

  public init(endpoint: URL, hostID: UUID, secret: String) {
    self.endpoint = endpoint
    self.hostID = hostID
    self.secret = secret
  }
}

public protocol RemoteClient: Sendable {
  func call(_ request: RemoteRequest) async throws -> RemoteResponse
}
