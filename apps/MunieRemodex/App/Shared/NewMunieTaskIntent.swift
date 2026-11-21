import AppIntents

struct NewMunieTaskIntent: AppIntent {
  static var title: LocalizedStringResource { "New Munie task" }
  static var description: IntentDescription {
    IntentDescription("Open Munie to review and send a request to your paired Mac.")
  }
  static let openAppWhenRun = true
  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .foreground }
  static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

  @MainActor
  func perform() async throws -> some IntentResult {
    RemodexQuickActionCenter.request(.newChat)
    return .result()
  }
}

struct MunieAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: NewMunieTaskIntent(),
      phrases: ["New task in \(.applicationName)"],
      shortTitle: "New Munie task", systemImageName: "square.and.pencil")
  }
}
