import Darwin
import Foundation
import MunieExecutionHost

private enum FixtureError: Error { case input, invariant, timeout }

private actor MappingBarrier: CodexExecutionAdapter {
  let inner: CodexAppServer
  let scenario: String
  init(inner: CodexAppServer, scenario: String) {
    self.inner = inner
    self.scenario = scenario
  }
  func start(_ submission: AuthorizedSubmission) async throws -> UpstreamTurn {
    let upstream = try await inner.start(submission)
    if scenario == "mapping-loss" {
      try MunieCodexHostProbe.emit([
        "milestone": .string("barrier"), "mode": .string("start"),
        "scenario": .string(scenario), "phase": .string("dispatching"),
      ])
      try await Task.sleep(for: .seconds(20))
      throw FixtureError.timeout
    }
    return upstream
  }
  func nextEvent() async throws -> CodexNativeEvent {
    let event = try await inner.nextEvent()
    if scenario == "mapped-crash", case .terminal = event.kind {
      // The native terminal has arrived; the coordinator has not committed it yet.
      try MunieCodexHostProbe.emit([
        "milestone": .string("barrier"), "mode": .string("start"),
        "scenario": .string(scenario), "phase": .string("running"),
      ])
      try await MunieCodexHostProbe.waitForControl()
      _ = try await inner.nextEvent()
      throw FixtureError.invariant
    }
    return event
  }
  func interrupt(_ upstream: UpstreamTurn) async throws { try await inner.interrupt(upstream) }
  func read(_ upstream: UpstreamTurn) async throws -> CodexTurnSnapshot? {
    try await inner.read(upstream)
  }
  func respondApproval(_ approval: CodexCommandApproval, decision: CodexApprovalDecision)
    async throws
  {
    try await inner.respondApproval(approval, decision: decision)
  }
  func close() async throws -> CodexTransportCleanup { try await inner.close() }
}

@main
struct MunieCodexHostProbe {
  private static let hostID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
  private static let projectID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
  private static let deviceID = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
  private static let requestID = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!
  private static let cases = [
    "text", "approval-cancel", "approval-accept", "running-interrupt",
    "pending-crash", "mapped-crash", "mapping-loss", "startup-loss",
  ]
  private static let effectCommand = "/bin/echo effect >> approval-effects"
  private static let runningCommand =
    "echo $$ > running-shell.pid; /bin/sleep 30 & child=$!; "
    + "echo $child > running-child.pid; wait $child; /usr/bin/touch after-interrupt"

  static func main() async {
    var transport: CodexStdioTransport?
    var session: HostCodexSession?
    var mode = "unknown"
    var scenario = "unknown"
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.count == 4, ["start", "recover"].contains(arguments[0]),
        cases.contains(arguments[1])
      else { throw FixtureError.input }
      mode = arguments[0]
      scenario = arguments[1]
      let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
      let codex = URL(fileURLWithPath: arguments[3])
      let workspace = root.appendingPathComponent("workspace", isDirectory: true)
      let home = root.appendingPathComponent("codex-data", isDirectory: true)
      let ledger = try HostSubmissionLedger(
        directoryURL: root.appendingPathComponent("state", isDirectory: true), hostID: hostID)
      let principal = AuthenticatedDevice(id: deviceID)
      let request = try TextSubmission(
        requestID: requestID, hostID: hostID, projectID: projectID,
        text: "Execute the Munie native host fixture: \(scenario)")
      if mode == "start" {
        try await ledger.registerProject(id: projectID, directoryURL: workspace)
        try await ledger.authorizeDevice(id: deviceID, projects: [projectID])
      }
      var limits = CodexTransportLimits()
      limits.readTimeout = .seconds(20)
      limits.sessionTimeout = .seconds(50)
      let launch = try CodexJSON.decode(
        Data(contentsOf: root.appendingPathComponent("launch.json")))
      guard let python = launch.object?["python"]?.string,
        let guardian = launch.object?["guardian"]?.string
      else { throw FixtureError.input }
      if scenario == "startup-loss" {
        try emit([
          "milestone": .string("arming"), "mode": .string(mode), "scenario": .string(scenario),
        ])
      }
      let native = try CodexStdioTransport(
        executableURL: URL(fileURLWithPath: python),
        arguments: [
          "-I", guardian, "--parent-pid", String(getpid()),
          "--registry", root.appendingPathComponent("native-\(mode).json").path,
          "--", "/usr/bin/sandbox-exec", "-f", root.appendingPathComponent("sandbox.sb").path,
          codex.path, "app-server", "--stdio",
        ],
        environment: [
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
          "CODEX_HOME": home.path, "TMPDIR": root.appendingPathComponent("tmp").path,
          "LANG": "en_US.UTF-8",
        ], workingDirectoryURL: workspace, limits: limits)
      transport = native
      if scenario == "startup-loss" {
        // Deliberately die after spawn but before the parent can receive a native-group frame.
        _ = kill(getpid(), SIGKILL)
        throw FixtureError.invariant
      }
      try emit([
        "milestone": .string("spawned"), "mode": .string(mode), "scenario": .string(scenario),
        "nativeGroup": .integer(Int64(native.processGroupID)),
      ])
      let client = try CodexAppServer(
        transport: native, workingDirectoryURL: workspace, codexHomeURL: home)
      try await client.initialize()
      let adapter: any CodexExecutionAdapter =
        ["mapping-loss", "mapped-crash"].contains(scenario) && mode == "start"
        ? MappingBarrier(inner: client, scenario: scenario) : client
      let coordinator = try HostCodexSession(ledger: ledger, adapter: adapter)
      session = coordinator
      let state = try await coordinator.submit(request, from: principal)
      var finalState: HostCodexTaskState
      var eventCount = 0
      var commandCompleted = false
      var commandExit: Int64?
      var resolved = false
      var agentMessageMatched = false
      var toolProcessesGoneBeforeClose = false
      if mode == "recover" {
        guard state.submission.phase == .reconciling else { throw FixtureError.invariant }
        finalState = try await coordinator.reconcile(requestID: requestID, from: principal)
        guard finalState.pendingApproval == nil, !finalState.cancellationRequested else {
          throw FixtureError.invariant
        }
        if scenario == "mapping-loss" {
          guard finalState.submission.phase == .reconciling,
            finalState.submission.upstream == nil
          else { throw FixtureError.invariant }
        } else if scenario == "mapped-crash" {
          guard finalState.submission.phase == .completed else { throw FixtureError.invariant }
        } else {
          guard [.reconciling, .cancelled, .failed].contains(finalState.submission.phase) else {
            throw FixtureError.invariant
          }
        }
      } else {
        guard state.submission.phase == .running, state.submission.upstream != nil else {
          throw FixtureError.invariant
        }
        let duplicate = try await coordinator.submit(request, from: principal)
        guard duplicate.submission == state.submission else { throw FixtureError.invariant }
        var terminal = false
        var interrupted = false
        while !terminal {
          let event: CodexNativeEvent
          do {
            event = try await coordinator.nextEvent(requestID: requestID, from: principal)
          } catch {
            guard ["pending-crash", "mapped-crash"].contains(scenario) else { throw error }
            let unknown = try await coordinator.snapshot(requestID: requestID, from: principal)
            guard unknown.submission.phase == .reconciling else { throw FixtureError.invariant }
            break
          }
          eventCount += 1
          guard eventCount <= 256 else { throw FixtureError.invariant }
          switch event.kind {
          case .approval(let approval):
            try validate(approval, scenario: scenario, workspace: workspace)
            if scenario == "pending-crash" {
              try emit([
                "milestone": .string("barrier"), "mode": .string(mode),
                "scenario": .string(scenario), "phase": .string("awaitingApproval"),
              ])
              try await waitForControl()
            } else {
              let decision: CodexApprovalDecision =
                scenario == "approval-cancel" ? .cancel : .accept
              _ = try await coordinator.respondApproval(
                requestID: requestID, approval: approval, decision: decision, from: principal)
              if scenario == "running-interrupt" {
                try await waitForTool(workspace)
                let ack = try await coordinator.interrupt(requestID: requestID, from: principal)
                guard ack.cancellationRequested, ack.submission.phase == .running else {
                  throw FixtureError.invariant
                }
                interrupted = true
              }
            }
          case .approvalResolved: resolved = true
          case .terminal(let snapshot):
            let expected: CodexTurnStatus =
              ["approval-cancel", "running-interrupt"].contains(scenario)
              ? .interrupted : .completed
            guard snapshot.status == expected else { throw FixtureError.invariant }
            terminal = true
          case .progress: break
          }
          if event.method == "item/completed", let item = event.payload.object?["item"]?.object,
            item["type"]?.string == "commandExecution"
          {
            guard item["id"]?.string == "call_host" else { throw FixtureError.invariant }
            commandCompleted = item["status"]?.string == "completed"
            commandExit = item["exitCode"]?.integer
          }
          if event.method == "item/completed", let item = event.payload.object?["item"]?.object,
            item["type"]?.string == "agentMessage"
          {
            guard item["text"]?.string == "MUNIE_FIXTURE_COMPLETE" else {
              throw FixtureError.invariant
            }
            agentMessageMatched = true
          }
        }
        finalState = try await coordinator.snapshot(requestID: requestID, from: principal)
        if scenario == "approval-accept" {
          guard resolved, commandCompleted, commandExit == 0, agentMessageMatched,
            finalState.submission.phase == .completed
          else { throw FixtureError.invariant }
        } else if scenario == "approval-cancel" {
          guard resolved, finalState.submission.phase == .cancelled else {
            throw FixtureError.invariant
          }
        } else if scenario == "running-interrupt" {
          guard interrupted, finalState.submission.phase == .cancelled else {
            throw FixtureError.invariant
          }
          try await verifyToolExit(workspace)
          toolProcessesGoneBeforeClose = true
        } else if scenario == "text" {
          guard agentMessageMatched, finalState.submission.phase == .completed else {
            throw FixtureError.invariant
          }
        }
      }
      let cleanup = try await coordinator.close()
      guard cleanup.complete else { throw FixtureError.invariant }
      try emit([
        "milestone": .string("result"), "mode": .string(mode), "scenario": .string(scenario),
        "phase": .string(finalState.submission.phase.rawValue),
        "hasUpstream": .bool(finalState.submission.upstream != nil),
        "pendingApproval": .bool(finalState.pendingApproval != nil),
        "eventCount": .integer(Int64(eventCount)), "commandCompleted": .bool(commandCompleted),
        "commandExit": commandExit.map(CodexJSON.integer) ?? .null,
        "toolProcessesGoneBeforeClose": .bool(toolProcessesGoneBeforeClose),
        "agentMessageMatched": .bool(agentMessageMatched),
        "cleanup": cleanupJSON(cleanup),
      ])
    } catch {
      var cleanup: CodexJSON = .null
      var cleanupError: CodexJSON = .null
      do {
        if let session {
          cleanup = cleanupJSON(try await session.close())
        } else if let transport {
          cleanup = cleanupJSON(try await transport.shutdown())
        }
      } catch { cleanupError = .string(safeCode(error)) }
      let failureDetails: CodexJSON
      if let failure = error as? HostCodexCloseFailure {
        failureDetails = .object([
          "persistence": failure.persistenceError.map { .string(safeCode($0)) } ?? .null,
          "transport": failure.transportError.map { .string(safeCode($0)) } ?? .null,
          "cleanup": failure.cleanup.map(cleanupJSON) ?? .null,
        ])
      } else if let failure = error as? HostCodexRecoveryFailure {
        failureDetails = .object([
          "primary": .string(safeCode(failure.primary)),
          "recovery": .string(safeCode(failure.recovery)),
        ])
      } else {
        failureDetails = .null
      }
      try? emit([
        "milestone": .string("failure"), "mode": .string(mode), "scenario": .string(scenario),
        "code": .string(safeCode(error)), "cleanup": cleanup, "cleanupError": cleanupError,
        "details": failureDetails,
      ])
      FileHandle.standardError.write(Data("Native host fixture failed\n".utf8))
      exit(1)
    }
  }

  private static func validate(
    _ approval: CodexCommandApproval, scenario: String, workspace: URL
  ) throws {
    let command = scenario == "running-interrupt" ? runningCommand : effectCommand
    guard
      ["approval-cancel", "approval-accept", "running-interrupt", "pending-crash"].contains(
        scenario),
      approval.itemID == "call_host", approval.command == "/bin/sh -c '\(command)'",
      approval.workingDirectory == workspace.path,
      approval.reason == "Munie native host fixture approval",
      approval.availableDecisions.contains(.string("accept")),
      approval.availableDecisions.contains(.string("cancel"))
    else { throw FixtureError.invariant }
  }

  private static func waitForTool(_ workspace: URL) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      if ["running-shell.pid", "running-child.pid"].allSatisfy({
        FileManager.default.fileExists(atPath: workspace.appendingPathComponent($0).path)
      }) {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.timeout
  }

  private static func verifyToolExit(_ workspace: URL) async throws {
    let pids = try ["running-shell.pid", "running-child.pid"].map { name -> Int32 in
      let text = try String(contentsOf: workspace.appendingPathComponent(name), encoding: .utf8)
      guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
        throw FixtureError.invariant
      }
      return pid
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline {
      if pids.allSatisfy({ kill($0, 0) < 0 && errno == ESRCH }) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.timeout
  }

  fileprivate static func waitForControl() async throws {
    let flags = fcntl(STDIN_FILENO, F_GETFL)
    guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw FixtureError.input
    }
    defer { _ = fcntl(STDIN_FILENO, F_SETFL, flags) }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    var byte: UInt8 = 0
    while clock.now < deadline {
      let count = Darwin.read(STDIN_FILENO, &byte, 1)
      if count == 1 { return }
      guard count < 0, [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) else {
        throw FixtureError.input
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.timeout
  }

  fileprivate static func emit(_ fields: [String: CodexJSON]) throws {
    var data = try CodexJSON.object(fields).encoded()
    data.append(10)
    FileHandle.standardOutput.write(data)
  }

  private static func cleanupJSON(_ cleanup: CodexTransportCleanup) -> CodexJSON {
    .object([
      "leaderExitStatus": cleanup.leaderExitStatus.map { .integer(Int64($0)) } ?? .null,
      "stdoutEOF": .bool(cleanup.stdoutEOF), "stderrEOF": .bool(cleanup.stderrEOF),
      "groupGone": .bool(cleanup.groupGone), "escalated": .bool(cleanup.escalated),
      "stdinBytes": .integer(Int64(cleanup.stdinBytes)),
      "stdoutBytes": .integer(Int64(cleanup.stdoutBytes)),
      "stderrBytes": .integer(Int64(cleanup.stderrBytes)),
    ])
  }

  private static func safeCode(_ error: any Error) -> String {
    switch error {
    case let value as CodexClientError: "client:\(value)"
    case let value as CodexTransportError: "transport:\(value)"
    case let value as SubmissionError: "ledger:\(value)"
    case let value as HostCodexSessionError: "session:\(value)"
    case let value as FixtureError: "fixture:\(value)"
    case is CancellationError: "cancelled"
    case is HostCodexRecoveryFailure: "recoveryFailure"
    case is HostCodexCloseFailure: "closeFailure"
    default: "unexpected"
    }
  }
}
