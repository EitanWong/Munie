import Foundation
import MunieExecutionHost
import SQLite3

@main
struct MunieSubmissionProbe {
  private static let hostID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  private static let projectID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
  private static let deviceID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
  private static let requestID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
  private static let upstream = UpstreamTurn(
    threadID: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
    turnID: UUID(uuidString: "10000000-0000-0000-0000-000000000006")!)
  private static let text = "Munie synthetic submission. No Codex or model was executed."

  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.count == 2 else { throw SubmissionError.invalidInput }
      let mode = arguments[0]
      guard
        [
          "accepted", "uncommitted", "claimed", "effect", "receipt", "terminal", "retry",
          "reconcile",
        ]
        .contains(mode)
      else { throw SubmissionError.invalidInput }
      let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
      let ledger = try HostSubmissionLedger(
        directoryURL: root.appendingPathComponent("state", isDirectory: true), hostID: hostID)
      let principal = AuthenticatedDevice(id: deviceID)
      let request = try TextSubmission(
        requestID: requestID, hostID: hostID, projectID: projectID, text: text)
      if mode == "retry" {
        if case .send = try await ledger.claimForDispatch(request, from: principal) {
          try effect(root)
          try await ledger.observeStarted(requestID: requestID, upstream: upstream)
          try await ledger.observeTerminal(
            requestID: requestID, upstream: upstream, phase: .completed)
        }
      } else if mode == "reconcile" {
        // Synthetic upstream evidence is deliberately separate from the host ledger commit.
        guard
          try String(contentsOf: root.appendingPathComponent("effects.txt"), encoding: .utf8)
            == "synthetic-upstream-effect\n"
        else { throw SubmissionError.upstreamConflict }
        try await ledger.observeStarted(requestID: requestID, upstream: upstream)
        try await ledger.observeTerminal(
          requestID: requestID, upstream: upstream, phase: .completed)
      } else {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
          at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try await ledger.registerProject(id: projectID, directoryURL: project)
        try await ledger.authorizeDevice(id: deviceID, projects: [projectID])
        _ = try await ledger.accept(request, from: principal)
        if mode == "uncommitted" {
          // Fault-only second connection: leave a real SQLite write transaction open, then die.
          // This is confined to the synthetic probe, never an execution-host API/backdoor.
          var connection: OpaquePointer?
          let databasePath = root.appendingPathComponent("state/submissions.sqlite3").path
          guard sqlite3_open_v2(databasePath, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
            let connection
          else { throw SubmissionError.invalidStorage }
          defer { sqlite3_close(connection) }
          guard
            sqlite3_exec(
              connection, "BEGIN IMMEDIATE; UPDATE requests SET phase='dispatching';", nil, nil, nil
            )
              == SQLITE_OK
          else { throw SubmissionError.invalidTransition }
          try emit([
            "mode": mode, "phase": "uncommitted-dispatching",
            "sqliteVersion": await ledger.sqliteVersion,
            "hasUpstream": "false", "provider": "synthetic-local-effect",
            "integrity": "ok",
          ])
          withExtendedLifetime(ledger) {
            _ = FileHandle.standardInput.readData(ofLength: 1)
          }
          return
        }
        if mode != "accepted" {
          guard case .send(let claim) = try await ledger.claimForDispatch(request, from: principal),
            claim.workingDirectory == project
          else { throw SubmissionError.invalidTransition }
          if mode != "claimed" {
            try effect(root)
            if mode != "effect" {
              try await ledger.observeStarted(requestID: requestID, upstream: upstream)
              if mode == "terminal" {
                try await ledger.observeTerminal(
                  requestID: requestID, upstream: upstream, phase: .completed)
              }
            }
          }
        }
      }
      let snapshot = try await ledger.snapshot(requestID: requestID, from: principal)
      try emit([
        "mode": mode, "phase": snapshot.phase.rawValue, "sqliteVersion": await ledger.sqliteVersion,
        "hasUpstream": String(snapshot.upstream != nil), "provider": "synthetic-local-effect",
        "integrity": "ok",
      ])
      if ["accepted", "claimed", "effect", "receipt"].contains(mode) {
        // A real pipe barrier, not a guessed delay. The parent kills us after seeing this line.
        withExtendedLifetime(ledger) {
          _ = FileHandle.standardInput.readData(ofLength: 1)
        }
      }
    } catch {
      // No raw storage paths or request content in the fixture's diagnostic stream.
      FileHandle.standardError.write(Data("Submission fixture failed\n".utf8))
      exit(1)
    }
  }

  private static func emit(_ fields: [String: String]) throws {
    var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
  }

  private static func effect(_ root: URL) throws {
    let file = root.appendingPathComponent("effects.txt")
    if !FileManager.default.fileExists(atPath: file.path) {
      guard
        FileManager.default.createFile(
          atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw SubmissionError.invalidStorage }
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("synthetic-upstream-effect\n".utf8))
    try handle.synchronize()
  }
}
