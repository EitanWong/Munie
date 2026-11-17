// Munie modification: self-hosted source fork; see ../NOTICE.md and LICENSE.
import SwiftUI

struct RevenueCatPaywallView: View {
    var body: some View {
        ContentUnavailableView("Self-hosted Munie", systemImage: "server.rack", description: Text("All client features are available without a subscription."))
    }
}
