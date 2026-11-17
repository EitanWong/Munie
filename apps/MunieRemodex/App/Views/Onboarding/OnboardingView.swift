// Munie modification: use the maintained local bridge scripts instead of upstream global install commands.
// Munie modification: self-hosted source fork; see ../NOTICE.md and LICENSE.
// FILE: OnboardingView.swift
// Purpose: Split onboarding flow — swipeable pages with fixed bottom bar.
// Layer: View
// Exports: OnboardingView
// Depends on: SwiftUI, OnboardingWelcomePage, OnboardingFeaturesPage, OnboardingStepPage

import SwiftUI

struct OnboardingView: View {
    let onScanQRCode: () -> Void
    let onPairWithCode: () -> Void
    @State private var currentPage = 0
    @State private var isShowingCodexInstallReminder = false

    private let pageCount = 5
    private let codexInstallStepIndex = 2
    private let codexInstallCommand = "npm install -g @openai/codex@0.162.1"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    OnboardingWelcomePage()
                        .tag(0)

                    OnboardingFeaturesPage()
                        .tag(1)

                    OnboardingStepPage(
                        stepNumber: 1,
                        icon: "terminal",
                        title: String(localized: "Install Codex CLI"),
                        description: String(localized: "Codex runs in Terminal on your Mac. Munie lets you control it from your iPhone."),
                        command: codexInstallCommand
                    )
                    .tag(2)

                    OnboardingStepPage(
                        stepNumber: 2,
                        icon: "link",
                        title: String(localized: "Prepare Munie on your Mac"),
                        description: String(localized: "From your Munie repository on the Mac, prepare the pinned local bridge."),
                        command: "./scripts/setup-remodex.sh",
                        commandCaption: String(localized: "Run from the Munie repository. The relay endpoint is configured locally and is not an upstream hosted service.")
                    )
                    .tag(3)

                    OnboardingStepPage(
                        stepNumber: 3,
                        icon: "qrcode.viewfinder",
                        title: String(localized: "Start Pairing"),
                        description: String(localized: "On your Mac, choose the Codex executable and authorized project. Scan the pairing QR code shown by the local bridge."),
                        command: "./scripts/run-remodex-local.sh --codex /absolute/codex --project /absolute/authorized/project"
                    )
                    .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .alert(String(localized: "Install Codex CLI First"), isPresented: $isShowingCodexInstallReminder) {
            Button(String(localized: "Stay Here"), role: .cancel) {}
                .accessibilityIdentifier("munie.onboarding.install.stay")
            Button(String(localized: "Understood")) {
                advanceToNextPage()
            }
            .accessibilityIdentifier("munie.onboarding.install.understood")
        } message: {
            Text(String(localized: "Before continuing, run \"\(codexInstallCommand)\" in Terminal on your Mac. Munie needs Codex CLI installed and available in your Mac's PATH."))
                .accessibilityIdentifier("munie.onboarding.install.message")
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 20) {
            // Animated pill dots
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i == currentPage ? Color.white : Color.white.opacity(0.18))
                        .frame(width: i == currentPage ? 24 : 8, height: 8)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentPage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Page \(currentPage + 1) of \(pageCount)"))
            .accessibilityIdentifier("munie.onboarding.pageIndicator")

            finalPageActions

            OpenSourceBadge(style: .light)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 50)
            .offset(y: -50),
            alignment: .top
        )
    }

    // MARK: - State

    @ViewBuilder
    private var finalPageActions: some View {
        if currentPage == pageCount - 1 {
            VStack(spacing: 10) {
                PrimaryCapsuleButton(
                    title: String(localized: "Scan with QR Code"),
                    systemImage: "qrcode",
                    action: handleContinue
                )
                .accessibilityIdentifier("munie.onboarding.scan")

                secondaryCapsuleButton(
                    title: String(localized: "Pair with Code"),
                    systemImage: "keyboard",
                    action: onPairWithCode
                )
                .accessibilityIdentifier("munie.onboarding.pairWithCode")
            }
        } else {
            PrimaryCapsuleButton(
                title: buttonTitle,
                action: handleContinue
            )
            .accessibilityIdentifier("munie.onboarding.continue")
        }
    }

    // Offers the first-run manual pairing path without competing visually with the primary QR flow.
    private func secondaryCapsuleButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RemodexIcon.image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))

                Text(title)
                    .font(AppFont.body(weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var buttonTitle: String {
        switch currentPage {
        case 0: return String(localized: "Get Started")
        case 1: return String(localized: "Set Up")
        default: return String(localized: "Continue")
        }
    }

    private func handleContinue() {
        // The CLI install step is a hard requirement, so warn before advancing.
        if currentPage == codexInstallStepIndex {
            isShowingCodexInstallReminder = true
            return
        }

        if currentPage < pageCount - 1 {
            advanceToNextPage()
        } else {
            onScanQRCode()
        }
    }

    private func advanceToNextPage() {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage += 1
        }
    }
}

// MARK: - Previews

#Preview("Full Flow") {
    OnboardingView(
        onScanQRCode: {
            print("Scan tapped")
        },
        onPairWithCode: {
            print("Code tapped")
        }
    )
}

#Preview("Light Override") {
    OnboardingView(
        onScanQRCode: {
            print("Scan tapped")
        },
        onPairWithCode: {
            print("Code tapped")
        }
    )
    .preferredColorScheme(.light)
}
