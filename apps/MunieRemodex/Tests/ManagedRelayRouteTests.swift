#if DEBUG
  import CryptoKit
  import Network
  import XCTest
  @testable import MunieRemodex

  @MainActor
  final class ManagedRelayRouteTests: XCTestCase {
    nonisolated deinit {}

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

    func testCancellingReconnectWhileLANDialIsPendingPreventsFallback() async {
      var reconnectIntent = true
      var managedAttempts = 0
      do {
        try await ContentViewModel.connectWithManagedFallback(shouldContinue: { reconnectIntent }) {
          reportUnreachable in
          await Task.yield()
          reconnectIntent = false
          reportUnreachable()
          throw NWError.posix(.ECONNREFUSED)
        } managed: {
          managedAttempts += 1
        }
        XCTFail("The cancelled reconnect must not publish a route")
      } catch is CancellationError {
        XCTAssertEqual(managedAttempts, 0)
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
  }
#endif
