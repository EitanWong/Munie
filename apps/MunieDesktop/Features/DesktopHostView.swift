import MunieNearby
import SwiftUI

struct DesktopHostView: View {
  let coordinator: DesktopCoordinator
  @ObservedObject var nearby: NearbyPairingHost

  private var controller: DesktopHostController { coordinator.controller }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        accountSection
        projectSection
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
    .onChange(of: controller.ready) { _, _ in coordinator.updateNearbyAvailability() }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "desktopcomputer")
        .font(.largeTitle)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Munie").font(.largeTitle.bold())
        Label(
          String(localized: controller.serviceState.title, table: "Desktop"),
          systemImage: controller.ready ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(controller.ready ? .green : .secondary)
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
        accountContent
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
        .disabled(!controller.ready || controller.projectBusy)
        .accessibilityIdentifier("desktop.chooseProject")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
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
            .disabled(coordinator.pairingBusy || !controller.ready)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("desktop.approvePairing")
            Button(String(localized: "Decline", table: "Desktop")) {
              coordinator.rejectPairing(request.id)
            }
            .disabled(coordinator.pairingBusy)
          }
        } else {
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
          .disabled(!controller.ready)
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

struct DesktopMenu: View {
  let coordinator: DesktopCoordinator
  @ObservedObject var nearby: NearbyPairingHost
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text(String(localized: coordinator.controller.serviceState.title, table: "Desktop"))
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
