// Munie modification: use the maintained local bridge scripts instead of upstream global install commands.
// Munie modification: self-hosted source fork; see ../NOTICE.md and LICENSE.
// FILE: OnboardingStepPage.swift
// Purpose: Single setup step page with icon, description, and command card.
// Layer: View
// Exports: OnboardingStepPage
// Depends on: SwiftUI, AppFont, OnboardingCommandCard

import SwiftUI

struct OnboardingStepPage: View {
    let stepNumber: Int
    let icon: String
    let title: String
    let description: String
    var command: String? = nil
    var commandCaption: String? = nil

    private let accentGradient = LinearGradient(
        colors: [Color(.plan).opacity(0.35), Color(.plan).opacity(0.08)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            // Subtle ambient radial glow
            RadialGradient(
                colors: [Color(.plan).opacity(0.06), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 340
            )
            .offset(y: -60)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 36) {
                    // Icon with gradient glow
                    ZStack {
                        // Soft glow behind icon
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color(.plan).opacity(0.18), .clear],
                                    center: .center,
                                    startRadius: 10,
                                    endRadius: 70
                                )
                            )
                            .frame(width: 140, height: 140)

                        RemodexIcon.image(systemName: icon)
                            .font(.system(size: 32, weight: .light))
                            .accessibilityHidden(true)
                            .foregroundStyle(.white)
                            .frame(width: 80, height: 80)
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(accentGradient, lineWidth: 1)
                            )
                    }

                    VStack(spacing: 12) {
                        // Step label
                        Text(String(localized: "STEP \(stepNumber)"))
                            .font(AppFont.caption2(weight: .bold))
                            .foregroundStyle(Color(.plan).opacity(0.7))
                            .kerning(1.5)

                        Text(title)
                            .accessibilityIdentifier("munie.onboarding.step.title.\(stepNumber)")
                            .font(AppFont.system(size: 28, weight: .bold))

                        Text(description)
                            .font(AppFont.subheadline(weight: .regular))
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let command {
                        VStack(alignment: .leading, spacing: 10) {
                            OnboardingCommandCard(command: command)
                                .accessibilityIdentifier("munie.onboarding.command.\(stepNumber)")

                            if let commandCaption, !commandCaption.isEmpty {
                                Text(commandCaption)
                                    .font(AppFont.caption())
                                    .foregroundStyle(.white.opacity(0.45))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)

                Spacer()
            }
        }
    }
}

// MARK: - Previews

#Preview("Step 1 — Codex CLI") {
    ZStack {
        Color.black.ignoresSafeArea()
        OnboardingStepPage(
            stepNumber: 1,
            icon: "terminal",
            title: String(localized: "Install Codex CLI"),
            description: String(localized: "Codex runs in Terminal on your Mac. Munie lets you control it from your iPhone."),
            command: "npm install -g @openai/codex@0.162.1"
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Step 2 — Bridge") {
    ZStack {
        Color.black.ignoresSafeArea()
        OnboardingStepPage(
            stepNumber: 2,
            icon: "link",
            title: String(localized: "Prepare Munie on your Mac"),
            description: String(localized: "From your Munie repository on the Mac, prepare the pinned local bridge."),
            command: "./scripts/setup-remodex.sh",
            commandCaption: String(localized: "Run from the Munie repository. The relay endpoint is configured locally and is not an upstream hosted service.")
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Step 3 — Pair") {
    ZStack {
        Color.black.ignoresSafeArea()
        OnboardingStepPage(
            stepNumber: 3,
            icon: "qrcode.viewfinder",
            title: String(localized: "Start Pairing"),
            description: String(localized: "On your Mac, choose the Codex executable and authorized project. Scan the pairing QR code shown by the local bridge."),
            command: "./scripts/run-remodex-local.sh --codex /absolute/codex --project /absolute/authorized/project"
        )
    }
    .preferredColorScheme(.dark)
}
