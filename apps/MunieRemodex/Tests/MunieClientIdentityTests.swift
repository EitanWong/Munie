import XCTest

@testable import MunieRemodex

@MainActor
final class MunieClientIdentityTests: XCTestCase {
  private static var retainedServices: [CodexService] = []

  func testHandshakeUsesMunieIdentityAndActualMarketingVersion() async {
    let service = CodexService(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    Self.retainedServices.append(service)
    var client: RPCObject?
    service.requestTransportOverride = { method, params in
      XCTAssertEqual(method, "initialize")
      client = params?.objectValue?["clientInfo"]?.objectValue
      throw CodexServiceError.invalidInput("End fixture before network startup")
    }
    do {
      try await service.initializeSession()
      XCTFail("Fixture transport should stop initialization")
    } catch {
      XCTAssertEqual(client?["name"]?.stringValue, "munie_ios")
      XCTAssertEqual(client?["title"]?.stringValue, "Munie iOS")
      XCTAssertEqual(
        client?["version"]?.stringValue,
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }
  }
}
