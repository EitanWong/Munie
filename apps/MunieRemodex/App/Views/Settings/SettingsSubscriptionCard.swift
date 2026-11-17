// Munie modification: self-hosted source fork; see ../NOTICE.md and LICENSE.
import SwiftUI

struct SettingsSubscriptionCard: View {
    let onShowPaywall: () -> Void
    let onRedeemCode: () -> Void
    var body: some View {
        SettingsCard(title: String(localized: "Self-hosted Munie"), footer: String(localized: "All client features are available without a subscription.")) {
            SettingsValueRow(title: String(localized: "Access"), value: String(localized: "Available"), valueColor: .green)
        }
    }
}
