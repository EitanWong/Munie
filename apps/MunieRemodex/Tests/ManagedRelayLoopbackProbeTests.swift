#if DEBUG && targetEnvironment(simulator)
  import XCTest
  @testable import MunieRemodex

  /// Opt-in device-local probe against the managed relay and Mac secure transport.
  @MainActor
  final class ManagedRelayLoopbackProbeTests: XCTestCase {
    nonisolated deinit {}

    func testUnreachableLANFallsBackToManagedEncryptedInitializeAndPreservesLANHint() async throws {
      guard let fixtureJSON = ProcessInfo.processInfo.environment["MUNIE_MANAGED_LOOPBACK_FIXTURE"]
      else {
        throw XCTSkip("Loopback interoperability fixture was not started")
      }
      let fixture = try JSONDecoder().decode(Fixture.self, from: Data(fixtureJSON.utf8))
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

      do {
        try await ContentViewModel().connect(
          codex: service, serverURL: lanSocket, shouldAttemptManagedFallback: { true })
        XCTAssertEqual(
          service.connectedServerIdentity, lanSocket, "The saved LAN route was tried first")
        XCTAssertNotNil(service.managedRelayAttemptID)
        XCTAssertTrue(service.isConnected)
        XCTAssertTrue(service.isInitialized)
        XCTAssertTrue(
          service.supportsRuntimeSettingsSync, "Plaintext predecessor must not resolve initialize")
        XCTAssertEqual(service.secureSession?.macDeviceId, mac.macDeviceId)
        XCTAssertEqual(service.relaySessionId, lanSessionID)
        XCTAssertEqual(service.relayUrl, lanURL)
        XCTAssertEqual(service.trustedMacRegistry.records[mac.macDeviceId]?.relayURL, lanURL)

        await service.disconnect()
        let nextSessionID = UUID().uuidString.lowercased()
        let nextSocket = "\(lanURL)/\(nextSessionID)"
        service.activeThreadId = "retained-thread"
        service.relaySessionId = nextSessionID
        service.shouldAutoReconnectOnForeground = true
        try await ContentViewModel().connect(
          codex: service, serverURL: nextSocket,
          shouldAttemptManagedFallback: { service.shouldAutoReconnectOnForeground })
        XCTAssertEqual(service.connectedServerIdentity, nextSocket)
        XCTAssertEqual(service.activeThreadId, "retained-thread")
        XCTAssertEqual(service.secureSession?.macDeviceId, mac.macDeviceId)
        XCTAssertEqual(service.relaySessionId, nextSessionID)
        XCTAssertNotNil(service.managedRelayAttemptID)
        XCTAssertTrue(service.isInitialized)
      } catch {
        await service.disconnect()
        throw error
      }
      await service.disconnect()
      XCTAssertNotEqual(service.relaySessionId, lanSessionID)
    }

    private struct Fixture: Decodable {
      let lanURL: String
      let macDeviceId: String
      let macIdentityPublicKey: String
      let phoneDeviceId: String
      let phoneIdentityPrivateKey: String
      let phoneIdentityPublicKey: String
    }
  }
#endif
