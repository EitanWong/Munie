#if DEBUG && targetEnvironment(simulator)
  import XCTest
  @testable import MunieRemodex

  /// Opt-in device-local probe against the managed relay and Mac secure transport.
  @MainActor
  final class ManagedRelayLoopbackProbeTests: XCTestCase {
    nonisolated deinit {}

    func testManagedReconnectUsesEncryptedInitializeAndPreservesLANHint() async throws {
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
      let lanURL = "ws://127.0.0.1:0/relay"
      let lanSessionID = UUID().uuidString.lowercased()
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

      do {
        try await service.connectManagedRelay(origin: fixture.origin, pinnedMac: mac)
        XCTAssertTrue(service.isConnected)
        XCTAssertTrue(service.isInitialized)
        XCTAssertTrue(
          service.supportsRuntimeSettingsSync, "Plaintext predecessor must not resolve initialize")
        XCTAssertEqual(service.secureSession?.macDeviceId, mac.macDeviceId)
        XCTAssertEqual(service.relaySessionId, lanSessionID)
        XCTAssertEqual(service.relayUrl, lanURL)
        XCTAssertEqual(service.trustedMacRegistry.records[mac.macDeviceId]?.relayURL, lanURL)
      } catch {
        await service.disconnect()
        throw error
      }
      await service.disconnect()
      XCTAssertEqual(service.relaySessionId, lanSessionID)
    }

    private struct Fixture: Decodable {
      let origin: String
      let macDeviceId: String
      let macIdentityPublicKey: String
      let phoneDeviceId: String
      let phoneIdentityPrivateKey: String
      let phoneIdentityPublicKey: String
    }
  }
#endif
