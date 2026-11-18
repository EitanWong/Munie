// Munie modification: self-hosted source fork; see ../NOTICE.md and LICENSE.
// FILE: CodexMobileApp.swift
// Purpose: App entry point, self-hosted root dependency wiring.
// Layer: App
// Exports: CodexMobileApp

import Combine
import SwiftUI

#if DEBUG
enum MunieAppLaunchRoute: Equatable {
    case production
    case timelineFixture
    case onboardingFixture
    case hostedTests

    static func resolve(arguments: [String], isHostedTest: Bool) -> Self {
        if arguments.contains("-CodexUITestsOnboardingFixture") {
            return .onboardingFixture
        }
        if arguments.contains("-CodexUITestsFixture") {
            return .timelineFixture
        }
        return isHostedTest ? .hostedTests : .production
    }

    // The selected factory alone is evaluated; fixture/test launches cannot initialize production stores.
    func makeRoot<Root>(
        production: () -> Root,
        timelineFixture: () -> Root,
        hostedTests: () -> Root,
        onboardingFixture: (() -> Root)? = nil
    ) -> Root {
        switch self {
        case .production: production()
        case .timelineFixture: timelineFixture()
        // Older test callers omit this factory; fail closed without constructing production stores.
        case .onboardingFixture: onboardingFixture?() ?? hostedTests()
        case .hostedTests: hostedTests()
        }
    }
}
#endif

// The fixture route is selected before constructing production services or stores.
@MainActor
@main
struct CodexMobileApp: App {
    @UIApplicationDelegateAdaptor(CodexMobileAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            MunieAppLaunchRoute.resolve(
                arguments: ProcessInfo.processInfo.arguments,
                isHostedTest: NSClassFromString("XCTestCase") != nil
                    || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            ).makeRoot(
                production: { AnyView(MunieProductionRootView()) },
                timelineFixture: { AnyView(MunieTimelineFixtureView()) },
                hostedTests: { AnyView(Color.clear) },
                onboardingFixture: { AnyView(MunieOnboardingFixtureView()) }
            )
            #else
            MunieProductionRootView()
            #endif
        }
    }
}

#if DEBUG
@MainActor
private struct MunieOnboardingFixtureView: View {
    private let preferences: UserDefaults

    init() {
        let suiteName = "app.munie.onboarding-ui-fixture"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create isolated onboarding fixture preferences")
        }
        preferences.removePersistentDomain(forName: suiteName)
        self.preferences = preferences

        // AppFont reads standard defaults directly. Override only its keys in the in-memory
        // argument domain, preserving language arguments and every persisted user preference.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[AppFont.storageKey] = AppFont.defaultStyle.rawValue
        arguments[AppFont.legacyStorageKey] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    var body: some View {
        // Exercise the actual five-page flow without constructing CodexService, Keychain stores,
        // scanner or pairing dependencies. External links and terminal callbacks cannot escape.
        OnboardingView(onScanQRCode: {}, onPairWithCode: {}, allowsNearbyDiscovery: false)
            .defaultAppStorage(preferences)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
    }
}
#endif

@MainActor
private struct MunieProductionRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppFont.storageKey) private var appFontStyleRawValue = AppFont.defaultStoredStyleRawValue
    // StateObject's lazy construction keeps service/store lifetime tied to the mounted production root.
    @StateObject private var dependencies = MunieProductionDependencies()

    var body: some View {
            ContentView()
                .font(activeBodyFont)
                .environment(dependencies.codexService)
                .environment(dependencies.petCompanionStore)
                .environment(dependencies.petCompanionStatusStore)
                .environment(dependencies.subscriptionService)
                .task {
                    await dependencies.subscriptionService.bootstrap()
                }
                .onOpenURL { url in
                    Task { @MainActor in
                        guard !routeRemodexDeepLink(url) else {
                            return
                        }
                        guard CodexService.legacyGPTLoginCallbackEnabled else {
                            return
                        }
                        await dependencies.codexService.handleGPTLoginCallbackURL(url)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    TurnCacheManager.resetAll()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .background else { return }
                    TurnCacheManager.resetAll()
                }
                // App init already set the appearance proxies before the first
                // window was built, so only live style changes need a re-apply
                // (which also walks existing windows to restyle mounted chrome).
                // Timeline caches hold text styled with the previous face, so drop them too.
                .onChange(of: appFontStyleRawValue) { _, _ in
                    AppTypographyController.apply()
                    TurnCacheManager.resetAll()
                }
    }

    private var activeBodyFont: Font {
        // Reading AppStorage here invalidates the root font environment as soon
        // as Settings changes the stored style, without rebuilding ContentView.
        _ = appFontStyleRawValue
        return AppFont.body()
    }

    @discardableResult
    private func routeRemodexDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.caseInsensitiveCompare("munie") == .orderedSame else {
            return false
        }

        let threadId = Self.remodexDeepLinkThreadID(from: url)

        let decodedThreadId = threadId?.removingPercentEncoding ?? threadId
        guard let normalizedThreadId = decodedThreadId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedThreadId.isEmpty else {
            return false
        }

        dependencies.codexService.handleNotificationOpen(threadId: normalizedThreadId, turnId: nil)
        return true
    }

    private static func remodexDeepLinkThreadID(from url: URL) -> String? {
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathComponents = url.pathComponents
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let host, isThreadRouteComponent(host) {
            return pathComponents.first
        }
        if host?.isEmpty != false,
           let route = pathComponents.first,
           Self.isThreadRouteComponent(route) {
            return pathComponents.dropFirst().first
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return queryItems.first { item in
            item.name.caseInsensitiveCompare("threadId") == .orderedSame
                || item.name.caseInsensitiveCompare("thread") == .orderedSame
        }?.value
    }

    private static func isThreadRouteComponent(_ value: String) -> Bool {
        value.caseInsensitiveCompare("thread") == .orderedSame
            || value.caseInsensitiveCompare("threads") == .orderedSame
    }

}

@MainActor
private final class MunieProductionDependencies: ObservableObject {
    let codexService: CodexService
    let petCompanionStore: PetCompanionStore
    let petCompanionStatusStore: PetCompanionStatusStore
    let subscriptionService: SubscriptionService

    init() {
        AppTypographyController.apply()
        codexService = CodexService()
        codexService.configureNotifications()
        petCompanionStore = PetCompanionStore()
        petCompanionStatusStore = PetCompanionStatusStore()
        subscriptionService = SubscriptionService()
    }
}
