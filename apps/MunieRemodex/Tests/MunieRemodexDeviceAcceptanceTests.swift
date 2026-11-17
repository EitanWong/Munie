import Foundation
import Security
import XCTest

@testable import MunieRemodex

/// Opt-in actual transport/account acceptance. Ordinary test entries exclude this class.
@MainActor
final class MunieRemodexDeviceAcceptanceTests: XCTestCase {
  func testExplicitDisposableTaskAndSeparateProcessRecovery() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let runID = environment["REMODEX_ACCEPTANCE_RUN_ID"], UUID(uuidString: runID) != nil,
      let mode = environment["REMODEX_ACCEPTANCE_MODE"],
      ["submit", "controls", "recover", "cleanup"].contains(mode),
      environment["REMODEX_ACCEPTANCE_AUTHORIZED"] == "disposable-project-only"
    else {
      throw XCTSkip("Requires explicit disposable project and bounded real-account authorization.")
    }
    let suiteName = "app.munie.remodex.acceptance." + runID
    let withControls = environment["REMODEX_ACCEPTANCE_WITH_CONTROLS"] == "fixed-marker-controls"
    guard mode != "controls" || withControls else { throw AcceptanceError.controlsNotAuthorized }
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    if mode == "cleanup" {
      // Exact UUID namespace only; no service is constructed and no network/model is used.
      let uuid = try XCTUnwrap(UUID(uuidString: runID))
      let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: bundleID + ".test-fixture." + uuid.uuidString.lowercased(),
      ]
      let status = SecItemDelete(query as CFDictionary)
      XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
      let applicationSupport = try XCTUnwrap(
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
      let fixtureDirectory = applicationSupport.appendingPathComponent(
        bundleID + ".test-fixture." + uuid.uuidString.lowercased(), isDirectory: true)
      if FileManager.default.fileExists(atPath: fixtureDirectory.path) {
        try FileManager.default.removeItem(at: fixtureDirectory)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureDirectory.path))
      defaults.removePersistentDomain(forName: suiteName)
      XCTAssertNil(SecureStore.readString(for: CodexSecureKeys.relaySessionId))
      XCTAssertNil(SecureStore.readData(for: CodexSecureKeys.phoneIdentityState))
      XCTAssertNil(SecureStore.readData(for: CodexSecureKeys.trustedMacRegistry))
      print("MUNIE_REMODEX_CLEANUP " + runID)
      return
    }
    let pairingText = try XCTUnwrap(environment["REMODEX_ACCEPTANCE_PAIRING"])
    let pairingData = try XCTUnwrap(pairingText.data(using: .utf8))
    let project = try XCTUnwrap(environment["REMODEX_ACCEPTANCE_PROJECT"])
    guard project.hasPrefix("/") else { throw AcceptanceError.unrelatedPairing }
    let pairing = try JSONDecoder().decode(CodexPairingQRPayload.self, from: pairingData)
    defaults.set(false, forKey: CodexService.keepMacAwakeWhileBridgeRunsDefaultsKey)
    let service = CodexService(defaults: defaults)
    service.suspendAutomaticMacScopedPersistence = true
    // Never replace another fixture or an existing trusted Mac.
    XCTAssertTrue(service.trustedMacRegistry.records.keys.allSatisfy { $0 == pairing.macDeviceId })
    guard service.trustedMacRegistry.records.keys.allSatisfy({ $0 == pairing.macDeviceId }),
      service.relayMacDeviceId == nil || service.relayMacDeviceId == pairing.macDeviceId
    else { throw AcceptanceError.unrelatedPairing }

    let marker = "MUNIE_REMODEX_REAL_OK"
    let prompt = "Reply exactly \(marker). Do not use tools."
    let previousPID = defaults.integer(forKey: "submitPID")
    let threadID: String
    var controlsResult: [String: Any] = [:]
    do {
      if mode == "submit" {
        guard defaults.string(forKey: "threadID") == nil else {
          throw AcceptanceError.alreadySubmitted
        }
        service.rememberRelayPairing(pairing)
      } else {
        XCTAssertNotEqual(previousPID, Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(service.relayMacDeviceId, pairing.macDeviceId)
      }
      try await service.connect(
        serverURL: pairing.relay + "/" + pairing.sessionId, token: "", role: "iphone",
        performInitialSync: false)
      XCTAssertEqual(service.secureConnectionState, .encrypted)

      if mode == "submit" {
        try await service.listModels()
        let thread = try await service.startThread(preferredProjectPath: project)
        threadID = thread.id
        // Persist the native identity before dispatch; a failed run never blindly resubmits.
        defaults.set(threadID, forKey: "threadID")
        defaults.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: "submitPID")
        try await service.startTurn(userInput: prompt, threadId: threadID)
      } else {
        threadID = try XCTUnwrap(defaults.string(forKey: "threadID"))
        try await service.listThreads(limit: 100)
        await service.syncThreadHistory(threadId: threadID, force: true)
      }
      if mode == "controls" {
        guard !defaults.bool(forKey: "controlsStarted") else {
          throw AcceptanceError.alreadySubmitted
        }
        defaults.set(true, forKey: "controlsStarted")
        service.setSelectedAccessMode(.onRequest)
        try await service.listModels()
        controlsResult = try await exerciseControls(
          service: service, threadID: threadID, project: project)
        defaults.set(true, forKey: "controlsCompleted")
      } else if mode == "recover", withControls {
        guard defaults.bool(forKey: "controlsCompleted") else {
          throw AcceptanceError.incompleteControls
        }
        try await waitForMarker(continuedMarker, service: service, threadID: threadID)
      }
      let deadline = ContinuousClock.now + .seconds(90)
      while ContinuousClock.now < deadline {
        let messages = service.messagesByThread[threadID] ?? []
        if messages.contains(where: {
          $0.role == .assistant && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == marker
        }),
          !service.runningThreadIDs.contains(threadID)
        {
          break
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      let messages = service.messagesByThread[threadID] ?? []
      var result: [String: Any] = [
        "mode": mode, "runID": runID, "threadID": threadID,
        "pid": Int(ProcessInfo.processInfo.processIdentifier), "previousPID": previousPID,
        "encrypted": service.secureConnectionState == .encrypted,
        "matchingUserMessages": messages.filter { $0.role == .user && $0.text == prompt }.count,
        "markerObserved": messages.contains {
          $0.role == .assistant && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == marker
        },
      ]
      result.merge(controlsResult) { _, control in control }
      print(
        "MUNIE_REMODEX_DIAGNOSTIC "
          + String(
            decoding: try JSONSerialization.data(
              withJSONObject: [
                "hasError": service.lastErrorMessage != nil,
                "running": service.runningThreadIDs.contains(threadID),
                "messages": messages.prefix(8).map {
                  [
                    "role": String(describing: $0.role), "utf8Bytes": $0.text.utf8.count,
                    "markerObserved": $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                      == marker,
                    "modelRejected": $0.text.contains("model_not_found"),
                  ] as [String: Any]
                },
              ], options: [.sortedKeys]), as: UTF8.self))
      XCTAssertTrue(
        messages.contains {
          $0.role == .assistant && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == marker
        })
      XCTAssertEqual(messages.filter { $0.role == .user && $0.text == prompt }.count, 1)
      XCTAssertFalse(service.runningThreadIDs.contains(threadID))
      print(
        "MUNIE_REMODEX_ACCEPTANCE "
          + String(
            decoding: try JSONSerialization.data(
              withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
      await service.disconnect()
      if mode == "recover" {
        service.forgetTrustedMac(deviceId: pairing.macDeviceId)
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertNil(SecureStore.readString(for: CodexSecureKeys.relaySessionId))
      }
    } catch {
      await service.disconnect()
      throw error
    }
  }

  private enum AcceptanceError: Error {
    case unrelatedPairing
    case alreadySubmitted
    case controlsNotAuthorized
    case incompleteControls
    case unexpectedApproval
    case terminalTimeout
    case incorrectMarker
  }

  private var continuedMarker: String { "MUNIE_REMODEX_CONTINUED_OK" }

  private func exerciseControls(service: CodexService, threadID: String, project: String)
    async throws
    -> [String: Any]
  {
    let approved = "printf 'MUNIE_REMODEX_APPROVED\\n' > munie-approved.txt"
    let waiting =
      "printf 'MUNIE_REMODEX_RUNNING\\n' > munie-running.txt; sleep 30; printf 'MUNIE_REMODEX_AFTER_WAIT\\n' > munie-after-wait.txt"
    var approvedIDs: Set<String> = []
    let first = try await requestFixedCommand(
      approved, service: service, threadID: threadID, project: project, approvedIDs: &approvedIDs)
    try await waitForTerminal(.completed, turnID: first, service: service, threadID: threadID)
    try await waitForFile(
      "munie-approved.txt", content: "MUNIE_REMODEX_APPROVED\n", service: service, project: project)

    let cancelled = try await requestFixedCommand(
      waiting, service: service, threadID: threadID, project: project, approvedIDs: &approvedIDs)
    try await waitForFile(
      "munie-running.txt", content: "MUNIE_REMODEX_RUNNING\n", service: service, project: project)
    try await service.interruptTurn(turnId: cancelled, threadId: threadID)
    try await waitForTerminal(.stopped, turnID: cancelled, service: service, threadID: threadID)

    let prompt = "Reply exactly \(continuedMarker). Do not use tools."
    try await service.startTurn(userInput: prompt, threadId: threadID)
    try await waitForMarker(continuedMarker, service: service, threadID: threadID)
    let messages = service.messagesByThread[threadID] ?? []
    let continued = try XCTUnwrap(
      messages.last(where: {
        $0.role == .assistant
          && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == continuedMarker
      })?.turnId)
    try await waitForTerminal(.completed, turnID: continued, service: service, threadID: threadID)
    guard messages.filter({ $0.role == .user && $0.text == prompt }).count == 1,
      Set([first, cancelled, continued]).count == 3
    else { throw AcceptanceError.incompleteControls }
    return [
      "approvalCount": approvedIDs.count, "approvalCommandMatched": true,
      "approvalCwdMatched": true,
      "approvedTurnID": first, "cancelledTurnID": cancelled, "continuedTurnID": continued,
      "runningMarkerObserved": true, "interruptionAcknowledged": true,
      "cancelledTerminalObserved": true, "continuationMarkerObserved": true,
    ]
  }

  private func requestFixedCommand(
    _ command: String, service: CodexService, threadID: String, project: String,
    approvedIDs: inout Set<String>
  ) async throws -> String {
    let prompt =
      "Use exec_command once with sandbox_permissions=require_escalated to force an explicit command approval, workdir exactly \(project), and cmd exactly: \(command)\nDo not run any other command or edit any other file. Do not change the shell command. This is workspace-write with an explicit approval, not read-only. After the command exits, reply briefly."
    try await service.startTurn(userInput: prompt, threadId: threadID)
    let deadline = ContinuousClock.now + .seconds(90)
    while ContinuousClock.now < deadline {
      if let request = service.pendingApprovals.first {
        guard service.pendingApprovals.count == 1,
          let turnID = request.turnId, UUID(uuidString: turnID) != nil,
          MunieAcceptanceCommandPolicy.matchesApproval(
            request, threadID: threadID, activeTurnID: service.activeTurnIdByThread[threadID],
            project: project, command: command),
          approvedIDs.insert(request.id).inserted
        else { throw AcceptanceError.unexpectedApproval }
        try await service.approvePendingRequest(request, forSession: false)
        return turnID
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw AcceptanceError.terminalTimeout
  }

  private func waitForTerminal(
    _ terminal: CodexTurnTerminalState, turnID: String, service: CodexService, threadID: String
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(90)
    while ContinuousClock.now < deadline {
      guard service.pendingApprovals.isEmpty else { throw AcceptanceError.unexpectedApproval }
      if service.turnTerminalState(for: turnID, threadId: threadID) == terminal,
        !service.runningThreadIDs.contains(threadID)
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw AcceptanceError.terminalTimeout
  }

  private func waitForMarker(_ marker: String, service: CodexService, threadID: String) async throws
  {
    let deadline = ContinuousClock.now + .seconds(90)
    while ContinuousClock.now < deadline {
      guard service.pendingApprovals.isEmpty else { throw AcceptanceError.unexpectedApproval }
      if (service.messagesByThread[threadID] ?? []).contains(where: {
        $0.role == .assistant && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == marker
      }), !service.runningThreadIDs.contains(threadID) {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw AcceptanceError.terminalTimeout
  }

  private func waitForFile(
    _ name: String, content: String, service: CodexService, project: String
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if let file = try? await service.readWorkspaceTextFile(path: name, cwd: project) {
        guard file.path == project + "/" + name, file.content == content else {
          throw AcceptanceError.incorrectMarker
        }
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw AcceptanceError.terminalTimeout
  }
}

enum MunieAcceptanceCommandPolicy {
  static func matchesApproval(
    _ request: CodexApprovalRequest, threadID: String, activeTurnID: String?, project: String,
    command: String
  ) -> Bool {
    guard request.method == "item/commandExecution/requestApproval", request.threadId == threadID,
      let turnID = request.turnId, UUID(uuidString: turnID) != nil, activeTurnID == turnID,
      request.params?.objectValue?["cwd"]?.stringValue == project, let observed = request.command
    else { return false }
    return matches(observed, expected: command)
  }

  static func matches(_ observed: String, expected: String) -> Bool {
    if observed == expected { return true }
    guard observed.utf8.count < expected.utf8.count * 4 + 200,
      let words = shellWords(observed), words.count == 3,
      ["/bin/zsh", "/bin/bash", "/bin/sh"].contains(words[0]),
      ["-c", "-lc"].contains(words[1])
    else { return false }
    return words[2] == expected
  }

  private static func shellWords(_ text: String) -> [String]? {
    var words: [String] = []
    var word = ""
    var quote: Character?
    var escaped = false
    var started = false
    for character in text {
      if escaped {
        if quote == "\"", character != "\"", character != "\\" { word.append("\\") }
        word.append(character)
        escaped = false
      } else if character == "\\", quote != "'" {
        escaped = true
        started = true
      } else if let current = quote {
        if character == current { quote = nil } else { word.append(character) }
      } else if character == "'" || character == "\"" {
        quote = character
        started = true
      } else if " \t\r\n".contains(character) {
        if started {
          words.append(word)
          word = ""
          started = false
        }
      } else {
        word.append(character)
        started = true
      }
    }
    guard quote == nil, !escaped else { return nil }
    if started { words.append(word) }
    return words
  }
}

@MainActor
final class MunieRemodexControlPolicyTests: XCTestCase {
  func testFixedBodyAllowsOnlyReviewedShellWrappers() {
    let command = "printf 'MUNIE_REMODEX_APPROVED\\n' > munie-approved.txt"
    XCTAssertTrue(MunieAcceptanceCommandPolicy.matches(command, expected: command))
    let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
    for shell in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
      for mode in ["-c", "-lc"] {
        XCTAssertTrue(
          MunieAcceptanceCommandPolicy.matches(shell + " " + mode + " " + quoted, expected: command)
        )
      }
    }
    for other in [
      command + "; touch injected", command + "\ntrue", "true; " + command,
      command + " $(touch injected)", command.replacingOccurrences(of: " > ", with: "  > "),
    ] {
      XCTAssertFalse(MunieAcceptanceCommandPolicy.matches(other, expected: command))
      let body = "'" + other.replacingOccurrences(of: "'", with: "'\\''") + "'"
      XCTAssertFalse(MunieAcceptanceCommandPolicy.matches("/bin/sh -c " + body, expected: command))
    }
    for launcher in ["/usr/bin/env sh", "/bin/fish", "/bin/sh --command"] {
      XCTAssertFalse(
        MunieAcceptanceCommandPolicy.matches(launcher + " " + quoted, expected: command))
    }
    XCTAssertFalse(
      MunieAcceptanceCommandPolicy.matches("/bin/sh -c \"unterminated", expected: command))
    XCTAssertFalse(
      MunieAcceptanceCommandPolicy.matches("/bin/sh -c " + quoted + " extra", expected: command))
  }

  func testApprovalBindsNativeMethodThreadTurnAndLiteralCwd() {
    let threadID = "947897ae-9143-4b07-9528-969623851a40"
    let turnID = "f467e369-b29e-4871-a4cf-3b17b99b668d"
    let command = "printf 'MUNIE_REMODEX_APPROVED\\n' > munie-approved.txt"
    let project = "/private/tmp/munie-fixture/project"
    for mismatch in ["none", "method", "thread", "turn", "cwd", "command", "missing-cwd"] {
      let request = CodexApprovalRequest(
        id: "synthetic-approval", requestID: .string("synthetic-approval"),
        method: mismatch == "method"
          ? "item/fileChange/requestApproval" : "item/commandExecution/requestApproval",
        command: mismatch == "command" ? command + "; true" : command, reason: nil,
        threadId: mismatch == "thread" ? "other-thread" : threadID,
        turnId: mismatch == "turn" ? UUID().uuidString : turnID,
        params: mismatch == "missing-cwd"
          ? nil : .object(["cwd": .string(mismatch == "cwd" ? project + "/child" : project)]))
      XCTAssertEqual(
        MunieAcceptanceCommandPolicy.matchesApproval(
          request, threadID: threadID, activeTurnID: turnID, project: project, command: command),
        mismatch == "none")
    }
  }
}
