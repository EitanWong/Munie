#if os(iOS)
  import AppIntents

  struct NewMunieTaskIntent: AppIntent {
    static var title: LocalizedStringResource {
      LocalizedStringResource("New Munie task", table: "Remote")
    }
    static var description: IntentDescription {
      IntentDescription(
        LocalizedStringResource(
          "Open Munie to review and send a request to your paired Mac.", table: "Remote"))
    }
    // Older supported OS releases use this property; iOS 26 uses supportedModes.
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult {
      RemoteNavigation.shared.openNewTask()
      return .result()
    }
  }

  struct MunieAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
      AppShortcut(
        intent: NewMunieTaskIntent(),
        phrases: ["New task in \(.applicationName)"],
        shortTitle: LocalizedStringResource("New Munie task", table: "Remote"),
        systemImageName: "square.and.pencil")
    }
  }
#endif
