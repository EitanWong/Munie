#if DEBUG && targetEnvironment(simulator)
  import XCTest
  @testable import MunieRemodex

  /// Opt-in device-local probe against the managed relay and Mac secure transport.
  @MainActor
  final class ManagedRelayLoopbackProbeTests: XCTestCase {
    nonisolated deinit {}

    func testUnreachableLANFallsBackToManagedEncryptedInitializeAndPreservesLANHint() async throws {
      try await exerciseLoopback(expectsPackagedPreview: false)
    }

    func testSignedPreviewReadsAuthorizedProjectAndRefusesTaskCreation() async throws {
      try await exerciseLoopback(expectsPackagedPreview: true)
    }

    func testSignedFixtureApprovesStopsAndRecoversExactlyOneSubmission() async throws {
      try await exerciseLoopback(expectsPackagedPreview: true, exercisesApproval: true)
    }

    private func exerciseLoopback(expectsPackagedPreview: Bool, exercisesApproval: Bool = false)
      async throws
    {
      guard let fixtureJSON = ProcessInfo.processInfo.environment["MUNIE_MANAGED_LOOPBACK_FIXTURE"]
      else {
        throw XCTSkip("Loopback interoperability fixture was not started")
      }
      let fixture = try JSONDecoder().decode(Fixture.self, from: Data(fixtureJSON.utf8))
      let packagedProject =
        try expectsPackagedPreview
        ? XCTUnwrap(fixture.authorizedProject, "Signed preview must supply its project")
        : nil
      let approvalDelay = fixture.approvalDelaySeconds
      guard approvalDelay == (exercisesApproval ? 8 : nil) else {
        throw ProbeFailure.invalidFixture
      }
      let service = CodexService()
      service.phoneIdentityState = CodexPhoneIdentityState(
        phoneDeviceId: fixture.phoneDeviceId,
        phoneIdentityPrivateKey: fixture.phoneIdentityPrivateKey,
        phoneIdentityPublicKey: fixture.phoneIdentityPublicKey)
      let lanURL = fixture.lanURL
      let lanSessionID = UUID().uuidString.lowercased()
      let lanSocket = "\(lanURL)/\(lanSessionID)"
      let mac = CodexTrustedMacRecord(
        macDeviceId: fixture.macDeviceId,
        macIdentityPublicKey: fixture.macIdentityPublicKey, lastPairedAt: .now, relayURL: lanURL)
      service.currentTrustedMacDeviceId = mac.macDeviceId
      service.trustedMacRegistry = CodexTrustedMacRegistry(records: [mac.macDeviceId: mac])
      service.relayMacDeviceId = mac.macDeviceId
      service.relaySessionId = lanSessionID
      service.relayUrl = lanURL
      service.isAppInForeground = false
      service.syncRealtimeEnabled = false
      service.suspendAutomaticMacScopedPersistence = true

      var stoppedTask: StoppedTask?
      do {
        try await ContentViewModel().connect(
          codex: service, serverURL: lanSocket, shouldAttemptManagedFallback: { true })
        XCTAssertEqual(
          service.connectedServerIdentity, lanSocket, "The saved LAN route was tried first")
        XCTAssertNotNil(service.managedRelayAttemptID)
        XCTAssertTrue(service.isConnected)
        XCTAssertTrue(service.isInitialized)
        XCTAssertTrue(service.supportsRuntimeSettingsSync, "Encrypted initialization must succeed")
        XCTAssertEqual(service.secureSession?.macDeviceId, mac.macDeviceId)
        XCTAssertEqual(service.relaySessionId, lanSessionID)
        XCTAssertEqual(service.relayUrl, lanURL)
        XCTAssertEqual(service.trustedMacRegistry.records[mac.macDeviceId]?.relayURL, lanURL)
        if let project = packagedProject {
          let listing = try await service.listProjectDirectory(path: project)
          XCTAssertEqual(listing.path, project)
          XCTAssertTrue(listing.entries.isEmpty)
          if let approvalDelay {
            stoppedTask = try await exerciseOneTimeApprovalAndStop(
              service: service, project: project, delay: .seconds(approvalDelay))
          } else {
            do {
              _ = try await service.sendRequest(
                method: "thread/start", params: .object(["cwd": .string(project)]))
              XCTFail("The configured Codex preview must remain read-only")
            } catch let CodexServiceError.rpcError(error) {
              XCTAssertEqual(
                error.data?.objectValue?["errorCode"]?.stringValue,
                "shared_codex_actions_unavailable")
            }
          }
        }

        await service.disconnect()
        let nextSessionID = UUID().uuidString.lowercased()
        let nextSocket = "\(lanURL)/\(nextSessionID)"
        let activeThread = stoppedTask?.threadID ?? "retained-thread"
        service.activeThreadId = activeThread
        service.relaySessionId = nextSessionID
        service.shouldAutoReconnectOnForeground = true
        try await ContentViewModel().connect(
          codex: service, serverURL: nextSocket,
          shouldAttemptManagedFallback: { service.shouldAutoReconnectOnForeground })
        XCTAssertEqual(service.connectedServerIdentity, nextSocket)
        XCTAssertEqual(service.activeThreadId, activeThread)
        XCTAssertEqual(service.secureSession?.macDeviceId, mac.macDeviceId)
        XCTAssertEqual(service.relaySessionId, nextSessionID)
        XCTAssertNotNil(service.managedRelayAttemptID)
        XCTAssertTrue(service.isInitialized)
        if let stoppedTask {
          XCTAssertTrue(
            service.pendingApprovals.isEmpty, "The replaced route must not replay a prompt")
          let resumed = try await service.sendRequest(
            method: "thread/resume",
            params: .object([
              "threadId": .string(stoppedTask.threadID), "excludeTurns": .bool(true),
            ]))
          XCTAssertEqual(
            resumed.result?.objectValue?["thread"]?.objectValue?["id"]?.stringValue,
            stoppedTask.threadID)
          try await assertCanonicalHistory(service: service, task: stoppedTask)
        }
      } catch {
        await service.disconnect()
        throw error
      }
      await service.disconnect()
      XCTAssertNotEqual(service.relaySessionId, lanSessionID)
    }

    private func exerciseOneTimeApprovalAndStop(
      service: CodexService, project: String, delay: Duration
    ) async throws -> StoppedTask {
      let start = try await service.sendRequest(
        method: "thread/start",
        params: .object(["cwd": .string(project), "ephemeral": .bool(false)]))
      let thread = try XCTUnwrap(start.result?.objectValue?["thread"]?.objectValue)
      let threadID = try XCTUnwrap(thread["id"]?.stringValue)
      guard UUID(uuidString: threadID) != nil, thread["cwd"]?.stringValue == project,
        start.result?.objectValue?["activePermissionProfile"]?.objectValue?["id"]?.stringValue
          == "munie_remote_shared_codex"
      else { throw ProbeFailure.invalidFixture }
      let prompt = "Munie signed simulator stop probe"
      let started = try await service.sendRequest(
        method: "turn/start",
        params: .object([
          "threadId": .string(threadID),
          "input": .array([.object(["type": .string("text"), "text": .string(prompt)])]),
        ]))
      let turnID = try XCTUnwrap(
        started.result?.objectValue?["turn"]?.objectValue?["id"]?.stringValue)
      XCTAssertNotNil(UUID(uuidString: turnID))
      try await waitFor("one projected command approval") { !service.pendingApprovals.isEmpty }
      let approval = try XCTUnwrap(service.pendingApprovals.first)
      let decisions = approval.params?.objectValue?["availableDecisions"]?.arrayValue?.compactMap(
        \.stringValue)
      // Abort without a reply unless all authority and execution fields match.
      guard service.pendingApprovals.count == 1, approval.threadId == threadID,
        approval.turnId == turnID,
        approval.method == "item/commandExecution/requestApproval",
        approval.command == "/bin/sh -c '/bin/sh managed-stop.sh'",
        approval.params?.objectValue?["cwd"]?.stringValue == project,
        approval.params?.objectValue?["itemId"]?.stringValue == "call_managed_stop_probe",
        let replyID = approval.requestID.stringValue, UUID(uuidString: replyID) != nil,
        let decisions, decisions.contains("accept"),
        Set(decisions).isSubset(of: ["accept", "decline", "cancel"]),
        decisions.count == approval.params?.objectValue?["availableDecisions"]?.arrayValue?.count
      else { throw ProbeFailure.unexpectedApproval }
      let beforeApproval = try await markerDirectories(service: service, project: project)
      XCTAssertTrue(beforeApproval.isEmpty, "The command must not run before the phone accepts it")
      guard beforeApproval.isEmpty else { throw ProbeFailure.unexpectedApproval }
      try await service.approvePendingRequest(approval)
      try await waitFor("native approval resolution and the command's start marker") {
        guard service.pendingApprovals.isEmpty else { return false }
        return try await self.markerDirectories(service: service, project: project).contains(
          "managed-shell-started")
      }
      let beforeStop = try await markerDirectories(service: service, project: project)
      XCTAssertEqual(beforeStop, ["managed-shell-started"])
      try await service.interruptTurn(turnId: turnID, threadId: threadID)
      try await waitFor("the host terminal event and resolved approval") {
        service.turnTerminalState(for: turnID, threadId: threadID) == .stopped
          && !service.runningThreadIDs.contains(threadID) && service.pendingApprovals.isEmpty
      }
      // Wait a full original delay after observing the start marker and stopping.
      try await Task.sleep(for: delay + .milliseconds(100))
      let afterDelay = try await markerDirectories(service: service, project: project)
      XCTAssertEqual(
        afterDelay, ["managed-shell-started"], "The stopped shell must not leave a late marker")
      let task = StoppedTask(threadID: threadID, turnID: turnID, prompt: prompt)
      try await assertCanonicalHistory(service: service, task: task)
      return task
    }

    private func markerDirectories(service: CodexService, project: String) async throws -> Set<
      String
    > {
      Set(try await service.listProjectDirectory(path: project).entries.map(\.name))
    }

    private func assertCanonicalHistory(service: CodexService, task: StoppedTask) async throws {
      let response = try await service.sendRequest(
        method: "thread/read",
        params: .object(["threadId": .string(task.threadID), "includeTurns": .bool(true)]))
      let thread = try XCTUnwrap(response.result?.objectValue?["thread"]?.objectValue)
      XCTAssertEqual(thread["id"]?.stringValue, task.threadID)
      let turns = try XCTUnwrap(thread["turns"]?.arrayValue?.compactMap(\.objectValue))
      XCTAssertEqual(turns.count, 1, "Recovery must not add another turn")
      let original = try XCTUnwrap(turns.first { $0["id"]?.stringValue == task.turnID })
      XCTAssertEqual(original["status"]?.stringValue, "interrupted")
      let items = try XCTUnwrap(original["items"]?.arrayValue?.compactMap(\.objectValue))
      let submitted = items.filter { $0["type"]?.stringValue == "userMessage" }
      XCTAssertEqual(submitted.count, 1, "Canonical history must contain one original submission")
      let input = try XCTUnwrap(submitted.first?["content"]?.arrayValue?.compactMap(\.objectValue))
      XCTAssertEqual(input.compactMap { $0["text"]?.stringValue }, [task.prompt])
    }

    private func waitFor(_ description: String, until ready: () async throws -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(12)
      while ContinuousClock.now < deadline {
        if try await ready() { return }
        try await Task.sleep(for: .milliseconds(100))
      }
      XCTFail("Timed out waiting for \(description)")
      throw ProbeFailure.timedOut
    }

    private enum ProbeFailure: Error {
      case invalidFixture
      case unexpectedApproval
      case timedOut
    }

    private struct StoppedTask {
      let threadID: String
      let turnID: String
      let prompt: String
    }

    private struct Fixture: Decodable {
      let lanURL: String
      let macDeviceId: String
      let macIdentityPublicKey: String
      let phoneDeviceId: String
      let phoneIdentityPrivateKey: String
      let phoneIdentityPublicKey: String
      let authorizedProject: String?
      let approvalDelaySeconds: Int?
    }
  }
#endif
