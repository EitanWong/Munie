// Munie modification: native Mac app discovery replaces terminal setup instructions.
import SwiftUI

struct OnboardingView: View {
  let onScanQRCode: () -> Void
  let onPairWithCode: () -> Void
  var onNearbyPairing: (CodexPairingQRPayload) async -> Bool = { _ in false }
  var onNearbyConnected: () -> Void = {}
  var onCancelNearbyConnection: () async -> Void = {}
  var allowsNearbyDiscovery = true
  @State private var currentPage = 0

  private let pageCount = 3

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: 0) {
        TabView(selection: $currentPage) {
          OnboardingWelcomePage().tag(0)
          OnboardingFeaturesPage().tag(1)
          NearbyMacConnectionView(
            allowsDiscovery: allowsNearbyDiscovery,
            isSelected: currentPage == 2,
            onPairing: onNearbyPairing,
            onConnected: onNearbyConnected,
            onCancelConnection: onCancelNearbyConnection
          )
          .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))

        VStack(spacing: 16) {
          HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
              Capsule()
                .fill(index == currentPage ? Color.white : Color.white.opacity(0.18))
                .frame(width: index == currentPage ? 24 : 8, height: 8)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(String(localized: "Page \(currentPage + 1) of \(pageCount)"))
          .accessibilityIdentifier("munie.onboarding.pageIndicator")

          if currentPage < pageCount - 1 {
            PrimaryCapsuleButton(
              title: currentPage == 0
                ? String(localized: "Get Started")
                : String(localized: "Find My Mac")
            ) {
              withAnimation(.easeInOut(duration: 0.3)) { currentPage += 1 }
            }
            .accessibilityIdentifier("munie.onboarding.continue")
          }
          OpenSourceBadge(style: .light)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
      }
    }
    .preferredColorScheme(.dark)
  }
}

#Preview {
  OnboardingView(onScanQRCode: {}, onPairWithCode: {}, allowsNearbyDiscovery: false)
}
