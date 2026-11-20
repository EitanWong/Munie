import MunieNearby
import SwiftUI

struct DesktopHostView: View {
  let coordinator: DesktopCoordinator
  @ObservedObject var nearby: NearbyPairingHost
  @State private var showingRemovePairing = false
  @State private var deviceToRemove: DesktopPairedDevice?
  @State private var showingOpenAIKeyEditor = false
  @State private var confirmingOpenAIKeyRemoval = false

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
    .sheet(isPresented: $showingOpenAIKeyEditor) {
      DesktopOpenAIKeyEditor(controller: controller)
    }
    .confirmationDialog(
      String(localized: "Remove OpenAI API Key?", table: "Desktop"),
      isPresented: $confirmingOpenAIKeyRemoval,
      titleVisibility: .visible
    ) {
      Button(String(localized: "Remove OpenAI API Key", table: "Desktop"), role: .destructive) {
        Task { await controller.removeOpenAIAPIKey() }
      }
    } message: {
      Text(
        "This removes the saved key and switches to ChatGPT. API-key conversations are kept.",
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
        if controller.modelProvider == .openAIAPIKey {
          Label(
            String(localized: "OpenAI API key configured", table: "Desktop"),
            systemImage: "key")
          Text("A configured key has not been verified with OpenAI.", tableName: "Desktop")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          accountContent
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
      HStack {
        Button(
          String(
            localized: controller.modelProvider == .openAIAPIKey
              ? "Replace OpenAI API Key…" : "Use OpenAI API Key…", table: "Desktop")
        ) {
          showingOpenAIKeyEditor = true
        }
        .accessibilityIdentifier("desktop.editOpenAIKey")
        if controller.modelProvider == .openAIAPIKey {
          Button(String(localized: "Switch to ChatGPT…", table: "Desktop")) {
            confirmingOpenAIKeyRemoval = true
          }
          .accessibilityIdentifier("desktop.removeOpenAIKey")
        }
      }
      .disabled(!controller.canChangeModelProvider)
      if controller.changingModelProvider {
        ProgressView().controlSize(.small)
      } else if controller.ready {
        Text("Stop Munie before changing the sign-in method.", tableName: "Desktop")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = controller.modelProviderError, !showingOpenAIKeyEditor {
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

private struct DesktopOpenAIKeyEditor: View {
  let controller: DesktopHostController
  @Environment(\.dismiss) private var dismiss
  @State private var key = ""
  @FocusState private var fieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("OpenAI API key", tableName: "Desktop").font(.headline)
      Text(
        "The key is saved in this Mac’s Keychain. Each sign-in method keeps its own conversations.",
        tableName: "Desktop"
      )
      .foregroundStyle(.secondary)
      SecureField(text: $key) { Text("OpenAI API key", tableName: "Desktop") }
        .focused($fieldFocused)
        .disabled(controller.changingModelProvider)
        .accessibilityIdentifier("desktop.openAIKey")
      if let error = controller.modelProviderError {
        Label(String(localized: error, table: "Desktop"), systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
      HStack {
        if controller.changingModelProvider { ProgressView().controlSize(.small) }
        Spacer()
        Button(String(localized: "Cancel", table: "Desktop"), role: .cancel) { dismiss() }
          .disabled(controller.changingModelProvider)
        Button(String(localized: "Save API Key", table: "Desktop")) {
          Task {
            if await controller.saveOpenAIAPIKey(key) { dismiss() }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(key.isEmpty || !controller.canChangeModelProvider)
        .accessibilityIdentifier("desktop.saveOpenAIKey")
      }
    }
    .padding(22)
    .frame(width: 440)
    .defaultFocus($fieldFocused, true)
    .interactiveDismissDisabled(controller.changingModelProvider)
    .onDisappear { key = "" }
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
