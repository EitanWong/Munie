#if os(iOS)
  import CryptoKit
  import Foundation
  import MunieRemote
  import Observation
  import UIKit

  @MainActor
  @Observable
  final class RemoteCoordinator {
    let model: RemoteModel
    let notifications = RemoteNotifications()
    private(set) var hasConnection = false
    private(set) var endpointLabel = ""
    private(set) var isPairing = false
    private(set) var pairingID: UUID?
    private(set) var pairingFingerprint: String?
    private(set) var lastConfirmedAt: Date?
    private(set) var lastSubmittedTaskID: UUID?
    var errorMessage: String?

    private let credentialStore = RemoteCredentialStore()
    private var expectedHostID: UUID?
    private var pairingTask: Task<Void, Never>?
    private var pairingGeneration = UUID()
    private var started = false

    init(model: RemoteModel? = nil) {
      let fileURL = URL.applicationSupportDirectory.appending(
        path: "Munie/Remote/pending-submission.json")
      self.model = model ?? RemoteModel(pendingStore: FilePendingSubmissionStore(fileURL: fileURL))
    }

    var shouldPoll: Bool {
      hasConnection && model.status?.tasks.contains(where: { !$0.phase.isTerminal }) == true
        && model.connection != .unauthorized
    }

    func start() async {
      guard !started else { return }
      started = true
      await notifications.install()
      do {
        if let credential = try await credentialStore.load() {
          try model.configure(
            endpoint: credential.endpoint, credential: credential.token,
            expectedHostID: credential.hostID)
          expectedHostID = credential.hostID
          endpointLabel = credential.endpoint.host ?? credential.endpoint.absoluteString
          hasConnection = true
          await model.restorePending()
          await refresh()
        }
      } catch {
        errorMessage = remoteString(
          "The saved connection could not be opened. Unlock this iPhone and try again.")
        started = false
      }
    }

    func refresh() async {
      await model.refresh()
      guard let status = model.status, model.connection == .connected else { return }
      guard status.hostID == expectedHostID else {
        model.disconnect()
        errorMessage = remoteString("The Mac identity changed. Verify the Mac and pair again.")
        return
      }
      lastConfirmedAt = Date()
      await notifications.observe(status)
    }

    func beginPairing(invitationText: String) {
      guard !isPairing else { return }
      errorMessage = nil
      guard invitationText.utf8.count <= 16_384 else {
        errorMessage = remoteString(
          "The pairing invitation is invalid. Create a new invitation on your Mac.")
        return
      }
      let invitation: PairingInvitation
      let client: RemoteHTTPClient
      let secret: String
      do {
        invitation = try JSONDecoder().decode(
          PairingInvitation.self, from: Data(invitationText.utf8))
        guard (32...512).contains(invitation.secret.utf8.count) else {
          throw RemoteClientError.invalidInput
        }
        client = try RemoteHTTPClient(endpoint: invitation.endpoint)
        secret = try RemoteCredentialStore.randomSecret()
      } catch {
        errorMessage = remoteString(
          "The pairing invitation is invalid. Create a new invitation on your Mac.")
        return
      }
      let id = UUID()
      let generation = UUID()
      pairingGeneration = generation
      pairingID = id
      pairingFingerprint = String(
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
      isPairing = true
      pairingTask = Task { [weak self] in
        guard let self else { return }
        defer {
          if self.pairingGeneration == generation {
            self.isPairing = false
            self.pairingTask = nil
          }
        }
        do {
          var response = try await client.call(
            RemoteRequest(
              op: .pair, invitation: invitation.secret, pairingID: id,
              pairingSecret: secret, deviceName: UIDevice.current.model))
          for _ in 0..<120 {
            try Task.checkCancellation()
            guard self.pairingGeneration == generation else { return }
            if response.pairingState == .approved, let token = response.credential {
              let authenticated = try RemoteHTTPClient(
                endpoint: invitation.endpoint, credential: token)
              let verification = try await authenticated.call(RemoteRequest(op: .status))
              guard verification.status?.hostID == invitation.hostID else {
                throw RemoteClientError.invalidResponse
              }
              try Task.checkCancellation()
              guard self.pairingGeneration == generation else { return }
              try await self.credentialStore.save(
                RemoteConnectionCredential(
                  endpoint: invitation.endpoint, hostID: invitation.hostID, token: token))
              guard self.pairingGeneration == generation else { return }
              try self.model.configure(
                endpoint: invitation.endpoint, credential: token, expectedHostID: invitation.hostID)
              try await self.completePairing(
                hostID: invitation.hostID, endpoint: invitation.endpoint)
              return
            }
            guard response.pairingState == .pending else {
              throw RemoteClientError.remote(.expired)
            }
            try await Task.sleep(for: .seconds(1))
            response = try await client.call(
              RemoteRequest(
                op: .pairStatus, invitation: invitation.secret, pairingID: id,
                pairingSecret: secret))
          }
          throw RemoteClientError.remote(.expired)
        } catch is CancellationError {
          return
        } catch {
          guard self.pairingGeneration == generation, !Task.isCancelled else { return }
          self.errorMessage = remoteString(
            "Pairing did not finish. Check the Mac and create a new invitation.")
        }
      }
    }

    /// Publishing removes the pairing view, whose disappearance cancels its task.
    /// Finish every suspension first so that removal cannot abort the first authoritative read.
    func completePairing(hostID: UUID, endpoint: URL) async throws {
      let generation = pairingGeneration
      expectedHostID = hostID
      endpointLabel = endpoint.host ?? endpoint.absoluteString
      await model.restorePending()
      await refresh()
      try Task.checkCancellation()
      guard pairingGeneration == generation else { throw CancellationError() }
      hasConnection = true
    }

    func cancelPairing() {
      pairingGeneration = UUID()
      pairingTask?.cancel()
      pairingTask = nil
      isPairing = false
      pairingID = nil
      pairingFingerprint = nil
    }

    func forgetConnection() async {
      cancelPairing()
      do {
        try await credentialStore.delete()
        model.disconnect()
        hasConnection = false
        expectedHostID = nil
        endpointLabel = ""
        lastConfirmedAt = nil
      } catch {
        errorMessage = remoteString(
          "The saved connection could not be removed. Unlock this iPhone and try again.")
      }
    }

    func pollWhileActive() async {
      while shouldPoll, !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard !Task.isCancelled, shouldPoll else { return }
        await refresh()
      }
    }

    func submit(projectID: UUID, taskID: UUID? = nil) async {
      let priorRequests = Set(model.status?.tasks.map(\.requestID) ?? [])
      lastSubmittedTaskID = nil
      await model.submit(text: model.draft, projectID: projectID, taskID: taskID)
      if model.lastError == nil, model.pendingSubmission == nil {
        lastSubmittedTaskID =
          model.status?.tasks.first {
            $0.projectID == projectID && !priorRequests.contains($0.requestID)
          }?.id
      }
      if let status = model.status { await notifications.observe(status) }
    }

    func registerNotificationToken(_ token: Data) async {
      do {
        guard let credential = try await credentialStore.load() else { return }
        let client = try RemoteHTTPClient(
          endpoint: credential.endpoint, credential: credential.token)
        let encoded = token.map { String(format: "%02x", $0) }.joined()
        _ = try await client.call(RemoteRequest(op: .registerNotifications, deviceToken: encoded))
      } catch {
        errorMessage = remoteString(
          "Remote notifications could not be registered. Manual task refresh remains available.")
      }
    }
  }
#endif
