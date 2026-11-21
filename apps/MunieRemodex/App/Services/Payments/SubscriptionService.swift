// Munie modification: self-hosted source fork; see ../NOTICE.md and LICENSE.
import Foundation
import Observation

enum SubscriptionBootstrapState: Equatable { case idle, loading, ready, failed }

@MainActor @Observable
final class SubscriptionService {
    // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
    nonisolated deinit {}

    private(set) var bootstrapState: SubscriptionBootstrapState = .ready
    let hasProAccess = true
    let freeSendCount = 0
    let remainingFreeSendAttempts = Int.max
    let hasFreeSendAccess = true
    let hasAppAccess = true
    let isLoading = false
    let isPurchasing = false
    let isRestoring = false
    let lastErrorMessage: String? = nil

    init(defaults: UserDefaults = .standard) {}
    func consumeFreeSendAttemptIfNeeded() {}
    func bootstrap() async {}
    func refreshCustomerInfoSilently() async {}
    func loadOfferings() async {}
    func restorePurchases() async {}
    func syncPurchasesAfterOfferCodeRedemption() async {}
}
