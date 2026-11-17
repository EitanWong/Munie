import Foundation
import MunieExecutionHost

enum LedgerNetworkCommand: Sendable {
  case accept(fingerprint: String, requestID: UUID, projectID: UUID, text: String)
  case claim(fingerprint: String, requestID: UUID, projectID: UUID, text: String)
  case snapshot(fingerprint: String, requestID: UUID)
  case revoke(deviceID: UUID)

  static func decode(_ data: Data) throws -> Self {
    guard data.count <= 4096, let fields = try CodexJSON.decode(data).object,
      let operation = fields["operation"]?.string
    else { throw LedgerNetworkProbeFailure.invalidRequest }
    if operation == "revoke" {
      guard Set(fields.keys) == ["operation", "deviceID"] else {
        throw LedgerNetworkProbeFailure.invalidRequest
      }
      return .revoke(deviceID: try LedgerNetworkConfiguration.canonicalID(fields["deviceID"]))
    }
    guard let fingerprint = fields["peerFingerprint"]?.string,
      LedgerNetworkConfiguration.isFingerprint(fingerprint)
    else { throw LedgerNetworkProbeFailure.invalidRequest }
    let requestID = try LedgerNetworkConfiguration.canonicalID(fields["requestID"])
    if operation == "snapshot" {
      guard Set(fields.keys) == ["operation", "peerFingerprint", "requestID"] else {
        throw LedgerNetworkProbeFailure.invalidRequest
      }
      return .snapshot(fingerprint: fingerprint, requestID: requestID)
    }
    guard ["accept", "claim"].contains(operation),
      Set(fields.keys) == ["operation", "peerFingerprint", "requestID", "projectID", "text"],
      let text = fields["text"]?.string
    else { throw LedgerNetworkProbeFailure.invalidRequest }
    let projectID = try LedgerNetworkConfiguration.canonicalID(fields["projectID"])
    if operation == "accept" {
      return .accept(
        fingerprint: fingerprint, requestID: requestID, projectID: projectID, text: text)
    }
    return .claim(fingerprint: fingerprint, requestID: requestID, projectID: projectID, text: text)
  }
}

/// Local trusted bridge for a synthetic TLS fixture. Stdin is not a remote or mobile API.
/// Only enrollment maps a certificate fingerprint to AuthenticatedDevice; request bodies cannot.
struct LedgerNetworkBridge: Sendable {
  let ledger: HostSubmissionLedger
  private let hostID: UUID
  private let registry: [String: AuthenticatedDevice]

  static func open(_ configuration: LedgerNetworkConfiguration) async throws -> Self {
    try configuration.validateDirectories()
    let ledger = try HostSubmissionLedger(
      directoryURL: configuration.stateDirectory, hostID: configuration.hostID)
    if configuration.initialize {
      for project in configuration.projects {
        try await ledger.registerProject(
          id: project, directoryURL: configuration.projectDirectory(project))
      }
      for device in configuration.devices {
        try await ledger.authorizeDevice(id: device.id, projects: device.projects)
      }
    }
    return Self(
      ledger: ledger, hostID: configuration.hostID,
      registry: Dictionary(
        uniqueKeysWithValues: configuration.devices.map {
          ($0.fingerprint, AuthenticatedDevice(id: $0.id))
        }))
  }

  func respond(to data: Data) async throws -> CodexJSON {
    let command: LedgerNetworkCommand
    do { command = try LedgerNetworkCommand.decode(data) } catch {
      return Self.error("invalid-request")
    }
    do {
      switch command {
      case .revoke(let deviceID):
        try await ledger.revokeDevice(id: deviceID)
        return .object(["event": .string("revoked")])
      case .snapshot(let fingerprint, let requestID):
        let device = try authenticatedDevice(fingerprint)
        let snapshot = try await ledger.snapshot(requestID: requestID, from: device)
        return Self.snapshot(snapshot)
      case .accept(let fingerprint, let requestID, let projectID, let text):
        let device = try authenticatedDevice(fingerprint)
        let request = try TextSubmission(
          requestID: requestID, hostID: hostID, projectID: projectID, text: text)
        return Self.snapshot(try await ledger.accept(request, from: device))
      case .claim(let fingerprint, let requestID, let projectID, let text):
        let device = try authenticatedDevice(fingerprint)
        let request = try TextSubmission(
          requestID: requestID, hostID: hostID, projectID: projectID, text: text)
        let claim = try await ledger.claimForDispatch(request, from: device)
        let send: Bool
        let phase: SubmissionPhase
        switch claim {
        case .send:
          send = true
          phase = .dispatching
        case .existing(let snapshot):
          send = false
          phase = snapshot.phase
        }
        // No effects, upstream tools or execution follow this fault-probe claim.
        return .object([
          "event": .string("result"), "state": .string("ledger-claim"),
          "requestID": .string(requestID.uuidString), "phase": .string(phase.rawValue),
          "send": .bool(send),
        ])
      }
    } catch let error as SubmissionError {
      switch error {
      case .unauthorized: return Self.error("unauthorized")
      case .requestConflict: return Self.error("request-conflict")
      case .unknownRequest: return Self.error("unknown-request")
      case .invalidInput: return Self.error("invalid-request")
      default: throw error
      }
    }
  }

  private func authenticatedDevice(_ fingerprint: String) throws -> AuthenticatedDevice {
    guard let device = registry[fingerprint] else { throw SubmissionError.unauthorized }
    return device
  }

  private static func error(_ code: String) -> CodexJSON {
    .object(["event": .string("result"), "error": .string(code)])
  }

  private static func snapshot(_ snapshot: SubmissionSnapshot) -> CodexJSON {
    .object([
      "event": .string("result"), "state": .string("ledger-snapshot"),
      "requestID": .string(snapshot.requestID.uuidString),
      "phase": .string(snapshot.phase.rawValue),
    ])
  }
}
