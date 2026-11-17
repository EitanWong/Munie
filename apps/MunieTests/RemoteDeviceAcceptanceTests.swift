#if os(iOS)
  import CryptoKit
  import Foundation
  import MunieRemote
  import XCTest

  @testable import Munie

  /// Opt-in physical-device evidence. Ordinary CI does not supply these private inputs.
  @MainActor
  final class RemoteDeviceAcceptanceTests: XCTestCase {
    private let marker = "MUNIE_PHONE_REAL_OK"

    func testPairSubmitRealTask() async throws {
      let environment = ProcessInfo.processInfo.environment
      guard environment["MUNIE_DEVICE_ACCEPTANCE_MODE"] == "submit",
        let encoded = environment["MUNIE_DEVICE_INVITATION"]
      else { throw XCTSkip("Opt-in physical-device acceptance is not configured.") }
      let invitation = try JSONDecoder().decode(PairingInvitation.self, from: Data(encoded.utf8))
      let store = RemoteCredentialStore()
      if let existing = try await store.load(),
        existing.hostID != invitation.hostID || existing.endpoint != invitation.endpoint
      {
        throw XCTSkip(
          "An existing different Mac pairing is preserved. Forget it explicitly before this opt-in fixture."
        )
      }
      let pairingID = UUID()
      let secret = try RemoteCredentialStore.randomSecret()
      let fingerprint = String(
        SHA256.hash(data: Data(secret.utf8))
          .map { String(format: "%02x", $0) }.joined().prefix(16))
      Self.output("MUNIE_DEVICE_PAIR \(pairingID.uuidString) \(fingerprint)")
      let client = try RemoteHTTPClient(endpoint: invitation.endpoint)
      let credential = try await Self.withDeadline(seconds: 120) {
        var response = try await client.call(
          RemoteRequest(
            op: .pair, invitation: invitation.secret,
            pairingID: pairingID, pairingSecret: secret, deviceName: "Munie iPhone acceptance"))
        while true {
          try Task.checkCancellation()
          if response.pairingState == .approved, let credential = response.credential {
            return credential
          }
          guard response.pairingState == .pending else { throw AcceptanceError.pairingRejected }
          try await Task.sleep(for: .seconds(1))
          response = try await client.call(
            RemoteRequest(
              op: .pairStatus, invitation: invitation.secret,
              pairingID: pairingID, pairingSecret: secret))
        }
      }
      let authenticated = try RemoteHTTPClient(
        endpoint: invitation.endpoint, credential: credential)
      let checked = try await authenticated.call(RemoteRequest(op: .status))
      let status = try XCTUnwrap(checked.status)
      XCTAssertEqual(status.hostID, invitation.hostID)
      XCTAssertTrue(status.codexReady)
      XCTAssertTrue(status.tasks.isEmpty, "This disposable host must begin without existing tasks.")
      let project = try XCTUnwrap(status.projects.first)
      // Recheck after the network awaits before changing the real app's connection slot.
      if let existing = try await store.load(),
        existing.hostID != invitation.hostID || existing.endpoint != invitation.endpoint
      {
        throw XCTSkip("A concurrently changed Mac pairing is preserved.")
      }
      try await store.save(
        RemoteConnectionCredential(
          endpoint: invitation.endpoint,
          hostID: invitation.hostID, token: credential))
      let model = makeModel(hostID: invitation.hostID)
      try model.configure(
        endpoint: invitation.endpoint, credential: credential,
        expectedHostID: invitation.hostID)
      await model.restorePending()
      XCTAssertFalse(model.hasUnresolvedRecovery)
      XCTAssertNil(
        model.pendingSubmission,
        "Existing acceptance recovery input must be inspected, not overwritten.")
      guard !model.hasUnresolvedRecovery, model.pendingSubmission == nil else {
        throw AcceptanceError.pendingRecovery
      }
      await model.refresh()
      XCTAssertNil(model.lastError)
      let prompt = "Reply exactly MUNIE_PHONE_REAL_OK. Do not use tools."
      model.draft = prompt
      await model.submit(text: prompt, projectID: project.id)
      XCTAssertNil(model.lastError)
      XCTAssertNil(model.pendingSubmission)
      let accepted = try XCTUnwrap(model.status?.tasks.first)
      let taskID = accepted.id
      let completed = try await waitForCompleted(model: model, taskID: taskID)
      XCTAssertEqual(completed.phase, .completed)
      XCTAssertTrue(hasExactMarker(completed))
      Self.output(
        "MUNIE_DEVICE_RESULT \(taskID.uuidString) \(ProcessInfo.processInfo.processIdentifier) \(completed.phase.rawValue)"
      )
    }

    func testRecoverSameTaskAfterProcessRestart() async throws {
      let environment = ProcessInfo.processInfo.environment
      guard environment["MUNIE_DEVICE_ACCEPTANCE_MODE"] == "recover",
        let rawTask = environment["MUNIE_DEVICE_EXPECTED_TASK_UUID"],
        let taskID = UUID(uuidString: rawTask),
        let rawHost = environment["MUNIE_DEVICE_EXPECTED_HOST_UUID"],
        let hostID = UUID(uuidString: rawHost)
      else { throw XCTSkip("Opt-in physical-device recovery is not configured.") }
      let store = RemoteCredentialStore()
      let saved = try await store.load()
      let credential = try XCTUnwrap(saved)
      XCTAssertEqual(credential.hostID, hostID)
      guard credential.hostID == hostID else { throw AcceptanceError.changedPairing }
      let model = makeModel(hostID: hostID)
      try model.configure(
        endpoint: credential.endpoint, credential: credential.token, expectedHostID: hostID)
      await model.restorePending()
      XCTAssertFalse(model.hasUnresolvedRecovery)
      XCTAssertNil(model.pendingSubmission)
      // This launch only reads authoritative state. No submit or retry operation is permitted.
      await model.refresh(taskID: taskID)
      XCTAssertNil(model.lastError)
      let status = try XCTUnwrap(model.status)
      XCTAssertEqual(status.tasks.count, 1)
      let task = try XCTUnwrap(status.tasks.first { $0.id == taskID })
      XCTAssertEqual(task.phase, .completed)
      XCTAssertTrue(hasExactMarker(task))
      Self.output(
        "MUNIE_DEVICE_RECOVERED \(taskID.uuidString) \(ProcessInfo.processInfo.processIdentifier) \(task.phase.rawValue)"
      )
      if environment["MUNIE_DEVICE_CLEAR_FIXTURE_CREDENTIAL"] == "1",
        let current = try await store.load(), current.hostID == hostID,
        current.token == credential.token
      {
        try await store.delete()
      }
    }

    private func makeModel(hostID: UUID) -> RemoteModel {
      let file = URL.applicationSupportDirectory.appending(
        path: "Munie/Remote/device-acceptance-\(hostID).json")
      return RemoteModel(pendingStore: FilePendingSubmissionStore(fileURL: file))
    }

    private func waitForCompleted(model: RemoteModel, taskID: UUID) async throws -> RemoteTask {
      try await Self.withDeadline(seconds: 150) { @MainActor in
        while true {
          try Task.checkCancellation()
          await model.refresh(taskID: taskID)
          if let task = model.status?.tasks.first(where: { $0.id == taskID }), task.phase.isTerminal
          {
            return task
          }
          try await Task.sleep(for: .seconds(1))
        }
      }
    }

    private func hasExactMarker(_ task: RemoteTask) -> Bool {
      task.messages.contains {
        $0.role == .assistant && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == marker
      }
    }

    nonisolated private static func output(_ line: String) {
      FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    nonisolated private static func withDeadline<Value: Sendable>(
      seconds: Int,
      operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
      try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
          try await Task.sleep(for: .seconds(seconds))
          throw AcceptanceError.deadline
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw AcceptanceError.deadline }
        return result
      }
    }

    private enum AcceptanceError: Error {
      case deadline, pairingRejected, changedPairing, pendingRecovery
    }
  }
#endif
