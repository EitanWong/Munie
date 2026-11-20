import MunieNearby
import SwiftUI

struct DesktopHostView: View {
  let coordinator: DesktopCoordinator
  @ObservedObject var nearby: NearbyPairingHost
  @State private var showingRemovePairing = false
  @State private var deviceToRemove: DesktopPairedDevice?
  @State private var providerEditor: DesktopProviderEditor.Mode?
  @State private var confirmingChatGPT = false

  private var controller: DesktopHostController { coordinator.controller }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        accountSection
        projectSection
        pairedPhoneSection
        pairingSection
        if let error = controller.error {
          Label(String(localized: error, table: "Desktop"), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .accessibilityIdentifier("desktop.error")
        }
        controls
      }
      .padding(28)
    }
    .alert(
      String(localized: "Remove iPhone Pairing?", table: "Desktop"),
      isPresented: $showingRemovePairing
    ) {
      Button(String(localized: "Remove Pairing", table: "Desktop"), role: .destructive) {
        guard let device = deviceToRemove else { return }
        deviceToRemove = nil
        Task { await controller.revokePairing(deviceID: device.id) }
      }
      Button(String(localized: "Keep Pairing", table: "Desktop"), role: .cancel) {
        deviceToRemove = nil
      }
    } message: {
      Text(
        "This removes all current iPhone pairings and disconnects them. The Mac service restarts and active work may stop. Pair again to reconnect.",
        tableName: "Desktop")
    }
    .sheet(item: $providerEditor) { mode in
      DesktopProviderEditor(controller: controller, mode: mode)
    }
    .confirmationDialog(
      String(localized: "Switch to ChatGPT?", table: "Desktop"),
      isPresented: $confirmingChatGPT,
      titleVisibility: .visible
    ) {
      Button(String(localized: "Switch to ChatGPT", table: "Desktop"), role: .destructive) {
        Task { await controller.switchToChatGPT() }
      }
    } message: {
      Text(
        "This removes the current provider’s saved key. Previous conversations and pairings are kept.",
        tableName: "Desktop")
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "desktopcomputer")
        .font(.largeTitle)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Munie").font(.largeTitle.bold())
        Label(
          String(localized: controller.statusTitle, table: "Desktop"),
          systemImage: controller.nearbyReady ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(controller.nearbyReady ? .green : .secondary)
        .accessibilityIdentifier("desktop.status")
      }
      Spacer()
      if controller.busy { ProgressView().controlSize(.small) }
    }
  }

  private var accountSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        Text("Your account", tableName: "Desktop").font(.headline)
        switch controller.modelProvider {
        case .openAIAPIKey:
          Label(
            String(localized: "OpenAI API key configured", table: "Desktop"),
            systemImage: "key")
          Text("A configured key has not been verified with OpenAI.", tableName: "Desktop")
            .font(.caption).foregroundStyle(.secondary)
        case .custom(let baseURL, let model):
          Label(
            String(localized: "Custom provider configured", table: "Desktop"),
            systemImage: "network")
          DesktopProviderDestination(
            endpoint: DesktopCustomProvider.responsesEndpoint(baseURL), model: model)
          Text("This provider has not been verified.", tableName: "Desktop")
            .font(.caption).foregroundStyle(.secondary)
        case .chatGPT:
          Label(String(localized: "ChatGPT", table: "Desktop"), systemImage: "person.crop.circle")
          accountContent
        case .unknown:
          Text("Provider status unavailable", tableName: "Desktop")
            .foregroundStyle(.secondary)
        }
        modelProviderControls
        Text(
          "Your Codex account stays on this Mac. Munie never sends account credentials to your iPhone.",
          tableName: "Desktop"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }

  private var modelProviderControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      Menu {
        Button(String(localized: "ChatGPT", table: "Desktop")) {
          confirmingChatGPT = true
        }
        .disabled(controller.modelProvider == .chatGPT)
        Button(String(localized: "OpenAI API Key…", table: "Desktop")) {
          providerEditor = .openAI
        }
        Button(String(localized: "Custom Provider…", table: "Desktop")) {
          providerEditor = .custom
        }
      } label: {
        Label(
          String(localized: "Model Provider", table: "Desktop"), systemImage: "slider.horizontal.3")
      }
      .disabled(!controller.canChangeModelProvider)
      .accessibilityIdentifier("desktop.modelProvider")
      if controller.changingModelProvider {
        ProgressView().controlSize(.small)
      } else if controller.ready {
        Text("Stop Munie before changing the sign-in method.", tableName: "Desktop")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = controller.modelProviderError, providerEditor == nil {
        Label(String(localized: error, table: "Desktop"), systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder private var accountContent: some View {
    switch controller.accountState {
    case .signedIn:
      Label(
        String(localized: "Signed in to Codex", table: "Desktop"), systemImage: "checkmark.shield")
    case .signingIn:
      Text("Finish signing in in your browser, then return to Munie.", tableName: "Desktop")
      HStack {
        Button(String(localized: "Open Sign-In Page", table: "Desktop")) {
          coordinator.reopenLogin()
        }
        Button(String(localized: "Cancel Sign-In", table: "Desktop")) {
          Task { await controller.cancelLogin() }
        }
        .disabled(controller.accountBusy)
      }
    case .unknown, .signedOut:
      Text("Sign in to use Codex from your iPhone.", tableName: "Desktop")
      Button(String(localized: "Sign In to Codex", table: "Desktop")) {
        Task { await coordinator.signIn() }
      }
      .disabled(!controller.ready || controller.accountBusy)
      .accessibilityIdentifier("desktop.signIn")
    }
  }

  private var projectSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        Text("Your project", tableName: "Desktop").font(.headline)
        if controller.projectName.isEmpty {
          Text("Munie creates a private project for you.", tableName: "Desktop")
            .foregroundStyle(.secondary)
        } else {
          Label(controller.projectName, systemImage: "folder")
        }
        Button(String(localized: "Choose Another Project…", table: "Desktop")) {
          Task { await coordinator.chooseProject() }
        }
        .disabled(!controller.ready || controller.projectBusy || controller.deviceBusy)
        .accessibilityIdentifier("desktop.chooseProject")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }

  private var pairedPhoneSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        Text("Paired iPhone", tableName: "Desktop").font(.headline)
        if !controller.hasPairingStatus {
          Text("Start Munie to check the paired iPhone.", tableName: "Desktop")
            .foregroundStyle(.secondary)
        } else if controller.pairedDevices.isEmpty {
          Text("No iPhone is paired with this Mac.", tableName: "Desktop")
            .foregroundStyle(.secondary)
        } else {
          Label(String(localized: "iPhone pairing saved", table: "Desktop"), systemImage: "iphone")
          Text(
            "Pairing allows your iPhone to connect. It does not mean the iPhone is online now.",
            tableName: "Desktop"
          )
          .font(.caption).foregroundStyle(.secondary)
          if controller.pairedDevices.count > 1 {
            Text(
              "More than one pairing was found. Removing pairing clears all of them.",
              tableName: "Desktop"
            )
            .foregroundStyle(.secondary)
          }
          HStack {
            Button(String(localized: "Remove Pairing…", table: "Desktop"), role: .destructive) {
              deviceToRemove = controller.pairedDevices.first
              showingRemovePairing = deviceToRemove != nil
            }
            .disabled(!controller.canRemovePairing)
            .accessibilityIdentifier("desktop.removePairing")
            if controller.deviceBusy {
              ProgressView().controlSize(.small)
              Text("Removing pairing…", tableName: "Desktop")
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
    .accessibilityIdentifier("desktop.pairedPhone")
  }

  @ViewBuilder private var pairingSection: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        Text("Connect your iPhone", tableName: "Desktop").font(.headline)
        if let request = nearby.pendingRequest {
          Text(request.deviceName).font(.headline)
          Text("Check that both screens show this number:", tableName: "Desktop")
          Text(request.verificationCode)
            .font(.system(.largeTitle, design: .monospaced).bold())
            .textSelection(.enabled)
            .accessibilityIdentifier("desktop.pairingCode")
          HStack {
            Button(String(localized: "Allow iPhone", table: "Desktop")) {
              Task { await coordinator.approvePairing(request.id) }
            }
            .disabled(coordinator.pairingBusy || !controller.nearbyReady || controller.deviceBusy)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("desktop.approvePairing")
            Button(String(localized: "Decline", table: "Desktop")) {
              coordinator.rejectPairing(request.id)
            }
            .disabled(coordinator.pairingBusy)
          }
        } else if !controller.ready || controller.nearbyReady {
          Text("Open Munie on your iPhone near this Mac and choose this Mac.", tableName: "Desktop")
          Text(
            "This version connects nearby. Connecting away from home is not ready yet.",
            tableName: "Desktop"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if coordinator.nearbyFailed || nearby.errorMessage != nil {
          Text(
            "Nearby discovery is unavailable. Check Local Network access and try again.",
            tableName: "Desktop"
          )
          .foregroundStyle(.secondary)
          Button(String(localized: "Retry Discovery", table: "Desktop")) {
            coordinator.updateNearbyAvailability()
          }
          .disabled(!controller.nearbyReady)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }

  private var controls: some View {
    HStack {
      if controller.canStart {
        Button(String(localized: "Start Munie", table: "Desktop")) {
          Task { await coordinator.start() }
        }
        .accessibilityIdentifier("desktop.start")
      }
      if controller.canStop {
        Button(
          String(
            localized: controller.serviceState == .cleanupUnconfirmed
              ? "Retry Stopping" : "Stop Munie",
            table: "Desktop")
        ) {
          Task { await coordinator.stop() }
        }
        .accessibilityIdentifier("desktop.stop")
      }
      Spacer()
      if controller.ready {
        Button(String(localized: "Refresh", table: "Desktop")) {
          Task { await controller.refresh() }
        }
      }
    }
    .disabled(controller.busy)
  }
}

private struct DesktopProviderEditor: View {
  enum Mode: String, Identifiable {
    case openAI, custom

    var id: String { rawValue }

    var title: String.LocalizationValue {
      switch self {
      case .openAI: "OpenAI API key"
      case .custom: "Custom Provider"
      }
    }
  }

  let controller: DesktopHostController
  let mode: Mode
  @Environment(\.dismiss) private var dismiss
  @State private var key = ""
  @State private var baseURL: String
  @State private var model: String
  @FocusState private var field: Field?

  private enum Field { case baseURL, key }

  init(controller: DesktopHostController, mode: Mode) {
    self.controller = controller
    self.mode = mode
    if case .custom(let baseURL, let model) = controller.modelProvider, mode == .custom {
      _baseURL = State(initialValue: baseURL)
      _model = State(initialValue: model)
    } else {
      _baseURL = State(initialValue: "")
      _model = State(initialValue: "")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(String(localized: mode.title, table: "Desktop")).font(.headline)
      VStack(alignment: .leading, spacing: 8) {
        if mode == .custom {
          VStack(alignment: .leading, spacing: 4) {
            Text("HTTPS base URL", tableName: "Desktop")
            TextField(text: $baseURL) { Text("HTTPS base URL", tableName: "Desktop") }
              .labelsHidden()
              .focused($field, equals: .baseURL)
              .accessibilityIdentifier("desktop.customBaseURL")
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Model ID", tableName: "Desktop")
            TextField(text: $model) { Text("Model ID", tableName: "Desktop") }
              .labelsHidden()
              .accessibilityIdentifier("desktop.customModel")
          }
          if DesktopCustomProvider.isValidBaseURL(baseURL) {
            DesktopProviderDestination(
              endpoint: DesktopCustomProvider.responsesEndpoint(baseURL), model: nil)
          }
          Text(
            "Model requests are sent to this provider. Verify the destination before saving.",
            tableName: "Desktop"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        SecureField(text: $key) { Text("API key", tableName: "Desktop") }
          .focused($field, equals: .key)
          .accessibilityIdentifier("desktop.providerKey")
      }
      .disabled(controller.changingModelProvider)
      if let error = controller.modelProviderError {
        Label(String(localized: error, table: "Desktop"), systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
      HStack {
        if controller.changingModelProvider { ProgressView().controlSize(.small) }
        Spacer()
        Button(String(localized: "Cancel", table: "Desktop"), role: .cancel) { dismiss() }
          .disabled(controller.changingModelProvider)
        Button(String(localized: "Save Provider", table: "Desktop"), action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(key.isEmpty || !controller.canChangeModelProvider)
          .accessibilityIdentifier("desktop.saveProvider")
      }
    }
    .padding(22)
    .frame(width: 440)
    .defaultFocus($field, mode == .custom ? .baseURL : .key)
    .interactiveDismissDisabled(controller.changingModelProvider)
    .onDisappear { key = "" }
  }

  private func save() {
    Task {
      let saved =
        switch mode {
        case .openAI: await controller.saveOpenAIAPIKey(key)
        case .custom:
          await controller.saveCustomProvider(baseURL: baseURL, model: model, apiKey: key)
        }
      if saved { dismiss() }
    }
  }
}

private struct DesktopProviderDestination: View {
  let endpoint: String
  let model: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Responses endpoint", tableName: "Desktop").font(.caption)
      ViewThatFits(in: .vertical) {
        endpointText
        ScrollView { endpointText }
      }
      .frame(maxHeight: 62, alignment: .topLeading)
      if let model {
        LabeledContent {
          Text(verbatim: model).textSelection(.enabled)
        } label: {
          Text("Model ID", tableName: "Desktop")
        }
      }
    }
  }

  private var endpointText: some View {
    Text(verbatim: endpoint)
      .font(.caption.monospaced())
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct DesktopMenu: View {
  let coordinator: DesktopCoordinator
  @ObservedObject var nearby: NearbyPairingHost
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text(String(localized: coordinator.controller.statusTitle, table: "Desktop"))
    if nearby.pendingRequest != nil {
      Text("Your iPhone is waiting for confirmation", tableName: "Desktop")
    }
    Button(String(localized: "Open Munie", table: "Desktop")) {
      openWindow(id: "munie")
      NSApp.activate(ignoringOtherApps: true)
    }
    if coordinator.controller.canStart {
      Button(String(localized: "Start Munie", table: "Desktop")) {
        Task { await coordinator.start() }
      }
    }
    if coordinator.controller.canStop {
      Button(
        String(
          localized: coordinator.controller.serviceState == .cleanupUnconfirmed
            ? "Retry Stopping" : "Stop Munie", table: "Desktop")
      ) {
        Task { await coordinator.stop() }
      }
    }
    Divider()
    Button(String(localized: "Quit Munie", table: "Desktop")) { NSApp.terminate(nil) }
  }
}

struct DesktopMenuLabel: View {
  @ObservedObject var nearby: NearbyPairingHost

  var body: some View {
    if nearby.pendingRequest != nil {
      Label(
        String(localized: "iPhone confirmation needed", table: "Desktop"),
        systemImage: "iphone")
    } else {
      Label("Munie", systemImage: "desktopcomputer")
    }
  }
}
