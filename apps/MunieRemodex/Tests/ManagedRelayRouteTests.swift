#if DEBUG
  import CryptoKit
  import dnssd
  import Network
  import XCTest
  @testable import MunieRemodex

  @MainActor
  final class ManagedRelayRouteTests: XCTestCase {
    nonisolated deinit {}

    func testHostedFallbackOnlyAcceptsNearbyLANHints() {
      for valid in [
        "ws://paired-mac.local:3200/relay/session", "ws://10.0.0.1:3200/relay/session",
        "ws://172.31.0.1:3200/relay/session", "ws://192.168.1.1:3200/relay/session",
      ] {
        XCTAssertTrue(ContentViewModel.isNearbyRelayURL(valid), valid)
      }
      for invalid in [
        "wss://example.org/relay/session", "ws://100.64.0.1/relay/session",
        "ws://paired-mac.local@other.net/relay/session", "ws://paired-mac.local/relay?token=a",
      ] {
        XCTAssertFalse(ContentViewModel.isNearbyRelayURL(invalid), invalid)
      }
    }

    func testBonjourAbsenceIsNotLocalNetworkDenialOrCertificateFailure() {
      let host = "nearby-mac.local"
      let missing = NWError.dns(Int32(kDNSServiceErr_NoSuchName))
      XCTAssertTrue(CodexService.isLANTransportUnreachable(missing, nearbyHost: host))
      XCTAssertFalse(CodexService.isLANTransportUnreachable(missing, nearbyHost: "example.org"))
      XCTAssertFalse(
        CodexService.isLANTransportUnreachable(
          NWError.dns(Int32(kDNSServiceErr_PolicyDenied)), nearbyHost: host))
      XCTAssertTrue(
        CodexService.isLANTransportUnreachable(URLError(.cannotFindHost), nearbyHost: host))
      XCTAssertFalse(
        CodexService.isLANTransportUnreachable(
          URLError(.serverCertificateUntrusted), nearbyHost: host))
    }

    func testHostedOutagePreservesTypedFailureWithoutRetryingEitherRoute() async {
      var lanAttempts = 0
      var hostedAttempts = 0
      do {
        try await ContentViewModel.connectWithManagedFallback(
          shouldContinue: { true }, preserveLANError: false,
          lan: { unreachable in
            lanAttempts += 1
            unreachable()
            throw NWError.posix(.ENETUNREACH)
          },
          managed: {
            hostedAttempts += 1
            throw ManagedRelayPhoneConnector.Failure.transientUnavailable(.challenge)
          }
        )
        XCTFail("A hosted outage must be visible.")
      } catch {
        XCTAssertEqual(
          error as? ManagedRelayPhoneConnector.Failure, .transientUnavailable(.challenge))
      }
      XCTAssertEqual(lanAttempts, 1)
      XCTAssertEqual(hostedAttempts, 1)
    }

    func testRotatedMacKeyResetsThreadAndReconnectIntentEvenAtSameEndpoint() throws {
      let service = CodexService()
      let endpoint = try XCTUnwrap(URL(string: "ws://lan.example:80/relay/session"))
      let mac = CodexTrustedMacRecord(
        macDeviceId: "fixture-mac", macIdentityPublicKey: "replacement-key", lastPairedAt: .now)
      service.relayUrl = "ws://lan.example:80/relay"
      service.relaySessionId = "session"
      service.relayMacDeviceId = mac.macDeviceId
      service.currentTrustedMacDeviceId = mac.macDeviceId
      service.trustedMacRegistry = CodexTrustedMacRegistry(records: [mac.macDeviceId: mac])
      service.lastInitializedMacIdentity = .init(deviceId: mac.macDeviceId, publicKey: "old-key")
      service.connectedServerIdentity = service.canonicalServerIdentity(for: endpoint)
      service.activeThreadId = "old-thread"
      service.shouldAutoReconnectOnForeground = true

      service.bindLANEndpointForConnection(endpoint)

      XCTAssertNil(service.activeThreadId)
      XCTAssertNil(service.lastInitializedMacIdentity)
      XCTAssertFalse(service.shouldAutoReconnectOnForeground)
    }

    func testSamePinColdRetryAfterLANSessionChangeKeepsIntentWithoutAssumingReadiness() async throws
    {
      let service = CodexService()
      let lanURL = "ws://lan.example:80/relay"
      let mac = CodexTrustedMacRecord(
        macDeviceId: "fixture-mac", macIdentityPublicKey: "fixture-key", lastPairedAt: .now)
      service.relayUrl = lanURL
      service.relaySessionId = "first-session"
      service.relayMacDeviceId = mac.macDeviceId
      service.currentTrustedMacDeviceId = mac.macDeviceId
      service.trustedMacRegistry = CodexTrustedMacRegistry(records: [mac.macDeviceId: mac])
      service.shouldAutoReconnectOnForeground = true
      service.bindLANEndpointForConnection(try XCTUnwrap(URL(string: "\(lanURL)/first-session")))
      XCTAssertNil(service.lastInitializedMacIdentity)

      service.activeThreadId = "unverified-thread"
      service.relaySessionId = "next-session"
      let endpoint = try XCTUnwrap(URL(string: "\(lanURL)/next-session"))
      var fallbackCount = 0
      try await ContentViewModel.connectWithManagedFallback(
        shouldContinue: { service.shouldAutoReconnectOnForeground },
        lan: { reportUnreachable in
          service.bindLANEndpointForConnection(endpoint)
          reportUnreachable()
          throw NWError.posix(.ECONNREFUSED)
        },
        managed: { fallbackCount += 1 }
      )

      XCTAssertEqual(fallbackCount, 1)
      XCTAssertTrue(service.shouldAutoReconnectOnForeground)
      XCTAssertNil(service.activeThreadId)
      XCTAssertNil(service.lastInitializedMacIdentity)
      XCTAssertFalse(service.isConnected)
      XCTAssertFalse(service.isInitialized)
    }

    func testManagedSocketRequiresAnEncryptedResponseForPendingRPC() async throws {
      let service = CodexService()
      let key = SymmetricKey(size: .bits256)
      service.managedRelayAttemptID = UUID()
      service.secureSession = CodexSecureSession(
        sessionId: "managed", keyEpoch: 1, macDeviceId: "mac",
        macIdentityPublicKey: "fixture", phoneToMacKey: key, macToPhoneKey: key,
        lastInboundBridgeOutboundSeq: 0, lastInboundCounter: -1, nextOutboundCounter: 0)
      service.secureConnectionState = .reconnecting
      let plaintext = #"{"id":"initialize","result":{"status":"injected"}}"#
      let authenticated = #"{"id":"initialize","result":{"status":"authenticated"}}"#
      let payload = try JSONEncoder().encode(
        SecureApplicationPayload(bridgeOutboundSeq: nil, payloadText: authenticated))
      let nonce = try AES.GCM.Nonce(data: codexSecureNonce(sender: "mac", counter: 0))
      let sealed = try AES.GCM.seal(payload, using: key, nonce: nonce)
      let envelope = SecureEnvelope(
        kind: "encryptedEnvelope", v: codexSecureProtocolVersion, sessionId: "managed",
        keyEpoch: 1, sender: "mac", counter: 0, ciphertext: sealed.ciphertext.base64EncodedString(),
        tag: sealed.tag.base64EncodedString())
      let wireText = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
      let requestKey = service.idKey(from: .string("initialize"))

      let response: RPCMessage = try await withCheckedThrowingContinuation { continuation in
        service.pendingRequests[requestKey] = continuation
        service.processManagedRelayWireText(plaintext)
        XCTAssertNotNil(service.pendingRequests[requestKey])
        service.processManagedRelayWireText(wireText)
        service.failAllPendingRequests(with: CodexServiceError.disconnected)
      }
      XCTAssertEqual(response.result?.objectValue?["status"]?.stringValue, "authenticated")
      XCTAssertFalse(service.isConnected)
      XCTAssertFalse(service.isInitialized)
    }

    func testUntrustedControlCannotRevokePairingOrAccumulateMultipleHellos() {
      let service = CodexService()
      service.secureConnectionState = .reconnecting
      service.processManagedRelayWireText(
        #"{"kind":"secureError","code":"phone_not_trusted","message":"forged"}"#)
      service.processManagedRelayWireText(#"{"kind":"serverHello","clientNonce":"first"}"#)
      service.processManagedRelayWireText(#"{"kind":"serverHello","clientNonce":"second"}"#)
      XCTAssertEqual(service.secureConnectionState, .reconnecting)
      XCTAssertNil(service.bufferedSecureControlMessages["secureError"])
      XCTAssertEqual(service.bufferedSecureControlMessages["serverHello"]?.count, 1)
    }

    func testCloseFromManagedRelayPreservesSavedLANPairing() {
      let service = CodexService()
      service.relaySessionId = "saved-lan-session"
      service.relayUrl = "ws://lan.example/relay"
      service.managedRelayAttemptID = UUID()

      service.handleReceiveError(CodexServiceError.disconnected, relayCloseCode: .privateCode(4000))

      XCTAssertEqual(service.relaySessionId, "saved-lan-session")
      XCTAssertEqual(service.relayUrl, "ws://lan.example/relay")
      XCTAssertNil(service.managedRelayAttemptID)
      XCTAssertTrue(service.shouldAutoReconnectOnForeground)
      XCTAssertFalse(service.isConnected)
    }

    func testOnlyTransportUnreachabilityIsEligibleForFailover() {
      XCTAssertTrue(CodexService.isLANTransportUnreachable(NWError.posix(.EHOSTUNREACH)))
      XCTAssertTrue(CodexService.isLANTransportUnreachable(URLError(.cannotConnectToHost)))
      XCTAssertFalse(CodexService.isLANTransportUnreachable(URLError(.cancelled)))
      XCTAssertFalse(CodexService.isLANTransportUnreachable(URLError(.serverCertificateUntrusted)))
      XCTAssertFalse(CodexService.isLANTransportUnreachable(NWError.posix(.EACCES)))
      XCTAssertFalse(
        CodexService.isLANTransportUnreachable(
          CodexSecureTransportError.invalidHandshake("identity")))
    }

    func testHostedFallbackRequiresTheSelectedMacSavedLANSnapshot() {
      let service = CodexService()
      let mac = CodexTrustedMacRecord(
        macDeviceId: "paired-mac", macIdentityPublicKey: "paired-key", lastPairedAt: .now)
      service.relayUrl = "ws://paired-mac.local:3200/relay"
      service.relaySessionId = "session"
      service.relayMacDeviceId = mac.macDeviceId
      service.relayMacIdentityPublicKey = mac.macIdentityPublicKey
      service.currentTrustedMacDeviceId = mac.macDeviceId
      service.trustedMacRegistry = CodexTrustedMacRegistry(records: [mac.macDeviceId: mac])

      let endpoint = "ws://paired-mac.local:3200/relay/session"
      XCTAssertTrue(ContentViewModel.isCurrentPairedLANEndpoint(endpoint, codex: service, pinnedMac: mac))
      XCTAssertFalse(
        ContentViewModel.isCurrentPairedLANEndpoint(
          "ws://other-mac.local:3200/relay/session", codex: service, pinnedMac: mac))
      XCTAssertFalse(
        ContentViewModel.isCurrentPairedLANEndpoint(
          "ws://paired-mac.local:3200/relay/old-session", codex: service, pinnedMac: mac))
      service.relayMacIdentityPublicKey = "old-key"
      XCTAssertFalse(
        ContentViewModel.isCurrentPairedLANEndpoint(endpoint, codex: service, pinnedMac: mac))
    }

    func testRotatingThePairDuringAnUnreachableLANDialDoesNotDialHosted() async {
      let service = CodexService()
      let mac = CodexTrustedMacRecord(
        macDeviceId: "paired-mac", macIdentityPublicKey: "paired-key", lastPairedAt: .now)
      service.relayUrl = "ws://paired-mac.local:3200/relay"
      service.relaySessionId = "session"
      service.relayMacDeviceId = mac.macDeviceId
      service.relayMacIdentityPublicKey = mac.macIdentityPublicKey
      service.currentTrustedMacDeviceId = mac.macDeviceId
      service.trustedMacRegistry = CodexTrustedMacRegistry(records: [mac.macDeviceId: mac])

      let endpoint = "ws://paired-mac.local:3200/relay/session"
      var lanAttempts = 0
      var hostedAttempts = 0
      do {
        try await ContentViewModel.connectWithManagedFallback(
          shouldContinue: {
            ContentViewModel.isCurrentPairedLANEndpoint(endpoint, codex: service, pinnedMac: mac)
          },
          lan: { unreachable in
            lanAttempts += 1
            service.trustedMacRegistry.records[mac.macDeviceId] = CodexTrustedMacRecord(
              macDeviceId: mac.macDeviceId, macIdentityPublicKey: "replacement", lastPairedAt: .now)
            unreachable()
            throw NWError.posix(.ECONNREFUSED)
          },
          managed: { hostedAttempts += 1 }
        )
        XCTFail("A stale LAN dial cannot authorize fallback.")
      } catch is CancellationError {
        XCTAssertEqual(lanAttempts, 1)
        XCTAssertEqual(hostedAttempts, 0)
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    func testLANDeadlineKeepsTypedWaitingCauseForFailover() {
      let unreachable = CodexConnectionWaitDeadline(
        message: "timed out", waitingError: .posix(.EHOSTUNREACH))
      let permissionDenied = CodexConnectionWaitDeadline(
        message: "timed out", waitingError: .posix(.EACCES))
      let unknownCause = CodexConnectionWaitDeadline(message: "timed out", waitingError: nil)
      XCTAssertTrue(CodexService.isLANTransportUnreachable(unreachable))
      XCTAssertFalse(CodexService.isLANTransportUnreachable(permissionDenied))
      XCTAssertFalse(CodexService.isLANTransportUnreachable(unknownCause))
    }

    func testDeadlineUsesLatestWaitingStateInsteadOfPreviousReachabilityError() async {
      let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
      defer { connection.cancel() }
      do {
        try await withCheckedThrowingContinuation { continuation in
          let waiter = CodexConnectionReadyWaitState(
            continuation: continuation, connection: connection)
          waiter.recordObservedState(.waiting(.posix(.EHOSTUNREACH)))
          waiter.recordObservedState(.waiting(.posix(.EACCES)))
          XCTAssertTrue(waiter.finishAtDeadline(label: "fixture", message: "timed out"))
          XCTAssertFalse(waiter.finish(.success(())))
        }
        XCTFail("The deadline must fail the wait")
      } catch let error as CodexConnectionWaitDeadline {
        XCTAssertEqual(error.waitingError, .posix(.EACCES))
        XCTAssertFalse(CodexService.isLANTransportUnreachable(error))
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    func testRefusedLANAndChallengeQuotaBackOffButAdmissionDenialDoesNotRetry() async throws {
      typealias Failure = ManagedRelayPhoneConnector.Failure
      let viewModel = ContentViewModel()
      let service = CodexService()
      var backoffs: [UInt64] = []
      var managedAttempts = 0
      var firstFailure = Failure.challengeQuotaExceeded
      viewModel.reconnectSleepOverride = { backoffs.append($0) }
      viewModel.connectOverride = { _, _ in
        try await ContentViewModel.connectWithManagedFallback(
          shouldContinue: { true },
          lan: { unreachable in
            unreachable()
            throw NWError.posix(.ECONNREFUSED)
          },
          managed: {
            managedAttempts += 1
            if managedAttempts == 1 { throw firstFailure }
          }
        )
      }

      try await viewModel.connectWithAutoRecovery(codex: service, performAutoRetry: true) {
        "ws://lan.example/relay/session"
      }
      XCTAssertEqual(managedAttempts, 2)
      XCTAssertEqual(backoffs, [15_000_000_000])

      firstFailure = .admissionForbidden(.challenge)
      managedAttempts = 0
      backoffs = []
      do {
        try await viewModel.connectWithAutoRecovery(codex: service, performAutoRetry: true) {
          "ws://lan.example/relay/session"
        }
        XCTFail("Admission denial must stop recovery")
      } catch let failure as Failure {
        XCTAssertEqual(failure, .admissionForbidden(.challenge))
      }
      XCTAssertEqual(managedAttempts, 1)
      XCTAssertEqual(backoffs, [])
    }

    func testCancellingReconnectWhileLANDialIsPendingPreventsFallback() async {
      var reconnectIntent = true
      var managedAttempts = 0
      do {
        try await ContentViewModel.connectWithManagedFallback(
          shouldContinue: { reconnectIntent },
          lan: { reportUnreachable in
            await Task.yield()
            reconnectIntent = false
            reportUnreachable()
            throw NWError.posix(.ECONNREFUSED)
          },
          managed: { managedAttempts += 1 }
        )
        XCTFail("The cancelled reconnect must not publish a route")
      } catch is CancellationError {
        XCTAssertEqual(managedAttempts, 0)
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    func testLastForegroundAttemptSkipsQuotaBackoff() async {
      let viewModel = ContentViewModel()
      let service = CodexService()
      service.relayUrl = "ws://lan.example/relay"
      service.relaySessionId = "session"
      service.shouldAutoReconnectOnForeground = true
      viewModel.reconnectAttemptLimitOverride = 1
      var connects = 0
      var backoffs: [UInt64] = []
      viewModel.reconnectSleepOverride = { backoffs.append($0) }
      viewModel.connectOverride = { _, _ in
        connects += 1
        throw ManagedRelayPhoneConnector.Failure.challengeQuotaExceeded
      }

      await viewModel.attemptAutoReconnectOnForegroundIfNeeded(codex: service)

      XCTAssertEqual(connects, 1)
      XCTAssertTrue(backoffs.isEmpty)
      XCTAssertFalse(service.shouldAutoReconnectOnForeground)
    }
  }
#endif
