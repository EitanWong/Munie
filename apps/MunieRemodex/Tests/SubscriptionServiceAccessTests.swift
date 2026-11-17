// Munie modification: self-hosted access replaces the upstream five-send commercial gate.
import XCTest
@testable import MunieRemodex

@MainActor final class SubscriptionServiceAccessTests: XCTestCase {
    func testSelfHostedAccessDoesNotRequirePurchaseOrQuota() async {
        let suiteName = "MunieSelfHostedAccess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(5, forKey: "codex.subscription.freeSendCount")
        let service = SubscriptionService(defaults: defaults)
        await service.bootstrap()
        for _ in 0..<100 { service.consumeFreeSendAttemptIfNeeded() }
        XCTAssertTrue(service.hasAppAccess)
        XCTAssertTrue(service.hasProAccess)
        XCTAssertEqual(service.freeSendCount, 0)
        XCTAssertEqual(service.bootstrapState, .ready)
    }
}
