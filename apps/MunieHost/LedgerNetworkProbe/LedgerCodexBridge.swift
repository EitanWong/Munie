import Foundation
import MunieExecutionHost

enum LedgerCodexScenario: String, Sendable {
  case text
  case approvalCancel = "approval-cancel"
  case approvalAccept = "approval-accept"
  case runningInterrupt = "running-interrupt"
  case pendingCrash = "pending-crash"

  static let effectCommand = "/bin/echo effect >> approval-effects"
  static let runningCommand =
    "echo $$ > running-shell.pid; /bin/sleep 30 & child=$!; "
    + "echo $child > running-child.pid; wait $child; /usr/bin/touch after-interrupt"

  static func fixtureDecisions(command: String) -> [CodexJSON] {
    [
      .string("accept"),
      .object([
        "acceptWithExecpolicyAmendment": .object([
          "execpolicy_amendment": .array([.string("/bin/sh"), .string("-c"), .string(command)])
        ])
      ]),
      .string("cancel"),
    ]
  }

  func validate(_ approval: CodexCommandApproval, directory: URL) throws {
    let command = self == .runningInterrupt ? Self.runningCommand : Self.effectCommand
    guard self != .text, approval.itemID.utf8.elementsEqual("call_host".utf8),
      approval.command.utf8.elementsEqual("/bin/sh -c '\(command)'".utf8),
      approval.workingDirectory.utf8.elementsEqual(directory.path.utf8),
      approval.reason?.utf8.elementsEqual("Munie native host fixture approval".utf8) == true,
      approval.availableDecisions == Self.fixtureDecisions(command: command)
    else { throw LedgerCodexFailure.fixtureMismatch }
  }
}

enum LedgerCodexFailure: Error {
  case invalidConfiguration, invalidApproval, fixtureMismatch, cleanupIncomplete
}

enum LedgerCodexCommand: Sendable {
  case submit(fingerprint: String, requestID: UUID, projectID: UUID, text: String)
  case control(operation: String, fingerprint: String, requestID: UUID)
  case approval(fingerprint: String, requestID: UUID, token: UUID, decision: CodexApprovalDecision)
  case revoke(UUID)

  static func decode(_ data: Data) throws -> Self {
    guard data.count <= 4096, let fields = try CodexJSON.decode(data).object,
      let operation = fields["operation"]?.string
    else { throw LedgerNetworkProbeFailure.invalidRequest }
    if operation == "revoke" {
      guard Set(fields.keys) == ["operation", "deviceID"] else {
        throw LedgerNetworkProbeFailure.invalidRequest
      }
      return .revoke(try LedgerNetworkConfiguration.canonicalID(fields["deviceID"]))
    }
    guard let fingerprint = fields["peerFingerprint"]?.string,
      LedgerNetworkConfiguration.isFingerprint(fingerprint)
    else { throw LedgerNetworkProbeFailure.invalidRequest }
    let requestID = try LedgerNetworkConfiguration.canonicalID(fields["requestID"])
    if operation == "submit" {
      guard Set(fields.keys) == ["operation", "peerFingerprint", "requestID", "projectID", "text"],
        let text = fields["text"]?.string
      else { throw LedgerNetworkProbeFailure.invalidRequest }
      return .submit(
        fingerprint: fingerprint, requestID: requestID,
        projectID: try LedgerNetworkConfiguration.canonicalID(fields["projectID"]), text: text)
    }
    if operation == "approval" {
      guard
        Set(fields.keys) == [
          "operation", "peerFingerprint", "requestID", "approvalToken", "decision",
        ],
        let raw = fields["decision"]?.string, let decision = CodexApprovalDecision(rawValue: raw)
      else { throw LedgerNetworkProbeFailure.invalidRequest }
      return .approval(
        fingerprint: fingerprint, requestID: requestID,
        token: try LedgerNetworkConfiguration.canonicalID(fields["approvalToken"]),
        decision: decision)
    }
    guard ["snapshot", "nextEvent", "interrupt", "reconcile"].contains(operation),
      Set(fields.keys) == ["operation", "peerFingerprint", "requestID"]
    else { throw LedgerNetworkProbeFailure.invalidRequest }
    return .control(operation: operation, fingerprint: fingerprint, requestID: requestID)
  }
}

/// Research-only authenticated coordinator facade. Stdin is a trusted fixture pipe, not public IPC.
/// Approval tokens expose no native payload. A fixture operator already knows the fixed command;
/// this does not provide the informed approval presentation a shipping mobile product requires.
actor LedgerCodexBridge {
  private struct Pending {
    let token: UUID
    let requestID: UUID
    let deviceID: UUID
    let approval: CodexCommandApproval
  }

  private let bridge: LedgerNetworkBridge
  private let session: HostCodexSession
  private let hostID: UUID
  private let projectID: UUID
  private let directory: URL
  private let scenario: LedgerCodexScenario
  private var pending: Pending?
  private var eventCounts: [UUID: Int] = [:]

  init(
    bridge: LedgerNetworkBridge, session: HostCodexSession,
    configuration: LedgerNetworkConfiguration, scenario: LedgerCodexScenario
  ) throws {
    guard let projectID = configuration.projects.first else {
      throw LedgerCodexFailure.invalidConfiguration
    }
    self.bridge = bridge
    self.session = session
    self.hostID = configuration.hostID
    self.projectID = projectID
    self.directory = configuration.projectDirectory(projectID)
    self.scenario = scenario
  }

  func respond(to data: Data) async throws -> CodexJSON {
    let command: LedgerCodexCommand
    do { command = try LedgerCodexCommand.decode(data) } catch {
      return Self.error("invalid-request")
    }
    do {
      switch command {
      case .revoke(let deviceID):
        try await bridge.ledger.revokeDevice(id: deviceID)
        if pending?.deviceID == deviceID { pending = nil }
        return .object(["event": .string("revoked")])
      case .submit(let fingerprint, let requestID, let project, let text):
        let device = try bridge.authenticatedDevice(fingerprint)
        guard project == projectID else { throw SubmissionError.unauthorized }
        let request = try TextSubmission(
          requestID: requestID, hostID: hostID, projectID: project, text: text)
        // Authorize before the coordinator's busy check. A legitimate second request may stay
        // durably accepted while busy; this call never claims or dispatches it.
        _ = try await bridge.ledger.accept(request, from: device)
        return response(try await session.submit(request, from: device), deviceID: device.id)
      case .approval(let fingerprint, let requestID, let token, let decision):
        let device = try bridge.authenticatedDevice(fingerprint)
        let current = try await session.snapshot(requestID: requestID, from: device)
        guard let pending, pending.token == token, pending.requestID == requestID,
          pending.deviceID == device.id, current.pendingApproval == pending.approval
        else { throw LedgerCodexFailure.invalidApproval }
        // Consume before suspending. A native RPC or authorization failure cannot reuse it.
        self.pending = nil
        let state = try await session.respondApproval(
          requestID: requestID, approval: pending.approval, decision: decision, from: device)
        return response(state, deviceID: device.id)
      case .control(let operation, let fingerprint, let requestID):
        let device = try bridge.authenticatedDevice(fingerprint)
        // Check the actual ledger before exposing state, consuming native events or controlling.
        let before = try await session.snapshot(requestID: requestID, from: device)
        switch operation {
        case "snapshot": return response(before, deviceID: device.id)
        case "interrupt":
          let state = try await session.interrupt(requestID: requestID, from: device)
          pending = nil
          return response(state, deviceID: device.id)
        case "reconcile":
          let state = try await session.reconcile(requestID: requestID, from: device)
          if state.pendingApproval == nil { pending = nil }
          return response(state, deviceID: device.id)
        default:
          if [.completed, .cancelled, .failed].contains(before.submission.phase) {
            return response(
              before, deviceID: device.id, eventKind: "none", agentMessageMatched: false)
          }
          let count = eventCounts[requestID, default: 0]
          guard count < 256, eventCounts.count < 100 || eventCounts[requestID] != nil else {
            throw LedgerCodexFailure.fixtureMismatch
          }
          let event = try await session.nextEvent(requestID: requestID, from: device)
          eventCounts[requestID] = count + 1
          let kind: String
          switch event.kind {
          case .progress: kind = "progress"
          case .approval(let approval):
            try scenario.validate(approval, directory: directory)
            pending = Pending(
              token: UUID(), requestID: requestID, deviceID: device.id, approval: approval)
            kind = "approval"
          case .approvalResolved:
            pending = nil
            kind = "approval-resolved"
          case .terminal:
            pending = nil
            kind = "terminal"
          }
          let matched = Self.agentMessageMatched(event)
          let after = try await session.snapshot(requestID: requestID, from: device)
          return response(after, deviceID: device.id, eventKind: kind, agentMessageMatched: matched)
        }
      }
    } catch let error as SubmissionError {
      switch error {
      case .unauthorized: return Self.error("unauthorized")
      case .requestConflict: return Self.error("request-conflict")
      case .unknownRequest: return Self.error("unknown-request")
      case .invalidInput: return Self.error("invalid-request")
      default: throw error
      }
    } catch LedgerCodexFailure.invalidApproval {
      return Self.error("invalid-approval")
    } catch let error as HostCodexSessionError {
      switch error {
      case .busy, .noActiveTask, .operationInProgress, .invalidTransition:
        return Self.error("invalid-state")
      case .staleApproval, .expiredApproval, .unavailableDecision:
        return Self.error("invalid-approval")
      default: throw error
      }
    }
  }

  private func response(
    _ state: HostCodexTaskState, deviceID: UUID, eventKind: String? = nil,
    agentMessageMatched: Bool? = nil
  ) -> CodexJSON {
    var fields: [String: CodexJSON] = [
      "event": .string("result"), "state": .string("codex-snapshot"),
      "requestID": .string(state.submission.requestID.uuidString),
      "phase": .string(state.submission.phase.rawValue),
      "hasUpstream": .bool(state.submission.upstream != nil),
      "cancellationRequested": .bool(state.cancellationRequested),
      "pendingApproval": .bool(state.pendingApproval != nil),
    ]
    if let pending, pending.deviceID == deviceID, pending.requestID == state.submission.requestID,
      state.pendingApproval == pending.approval
    {
      fields["approvalToken"] = .string(pending.token.uuidString)
    }
    if let eventKind { fields["eventKind"] = .string(eventKind) }
    if let agentMessageMatched { fields["agentMessageMatched"] = .bool(agentMessageMatched) }
    return .object(fields)
  }

  private static func agentMessageMatched(_ event: CodexNativeEvent) -> Bool {
    guard event.method == "item/completed", let item = event.payload.object?["item"]?.object,
      item["type"]?.string == "agentMessage", let text = item["text"]?.string
    else { return false }
    return text.utf8.elementsEqual("MUNIE_FIXTURE_COMPLETE".utf8)
  }

  private static func error(_ code: String) -> CodexJSON {
    .object(["event": .string("result"), "error": .string(code)])
  }
}
