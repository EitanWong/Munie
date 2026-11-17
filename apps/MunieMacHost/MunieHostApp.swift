import AppKit
import CoreImage.CIFilterBuiltins
import MunieHostTransport
import MunieProductHost
import MunieRemote
import Observation
import ServiceManagement
import SwiftUI

@main
struct MunieHostApp: App {
  @State private var controller = HostController()
  @NSApplicationDelegateAdaptor(HostApplicationDelegate.self) private var delegate

  var body: some Scene {
    Window("Munie Host", id: "host") {
      HostView(controller: controller)
        .frame(minWidth: 600, minHeight: 560)
        .task {
          delegate.controller = controller
          if UserDefaults.standard.bool(forKey: "serviceEnabled") { await controller.start() }
        }
    }
    MenuBarExtra("Munie Host", systemImage: "desktopcomputer") {
      Button(String(localized: "Open Munie Host", table: "Host")) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
      }
      Button(String(localized: "Quit Munie Host", table: "Host")) { NSApp.terminate(nil) }
    }
  }
}

@MainActor
final class HostApplicationDelegate: NSObject, NSApplicationDelegate {
  weak var controller: HostController?
  private var terminationPending = false
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller else { return .terminateNow }
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    Task {
      let stopped = await controller.stop(disableStartup: false)
      terminationPending = false
      sender.reply(toApplicationShouldTerminate: stopped)
    }
    return .terminateLater
  }
}

@MainActor @Observable
final class HostController {
  var executable =
    UserDefaults.standard.string(forKey: "nativeCodexPath")
    ?? "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
  var endpoint = UserDefaults.standard.string(forKey: "hostEndpoint") ?? ""
  var status: RemoteStatus?
  var candidate: ProductPairingCandidate?
  var invitation: PairingInvitation?
  var devices: [ProductDeviceSummary] = []
  var selectedProjects: Set<UUID> = []
  var error = false
  var cleanupFailed = false
  var busy: Bool { starting != nil || stopping != nil }
  var listening = false
  var invitationExpiresAt: Date?
  private var host: ProductHost?
  private var server: HostHTTPServer?
  private var push: HostPushNotifications?
  private var closeStartupProbe: (@Sendable () async throws -> Void)?
  private var starting: Task<Void, Never>?
  private var stopping: Task<Bool, Never>?

  var canStart: Bool { !busy && host == nil && closeStartupProbe == nil && !cleanupFailed }
  var serviceState: String.LocalizationValue {
    if cleanupFailed { return "Service cleanup not confirmed" }
    if stopping != nil { return "Stopping Mac service…" }
    if starting != nil { return "Starting Mac service…" }
    return listening ? "Mac service running" : "Mac service stopped"
  }

  func start() async {
    guard canStart else { return }
    let task = Task { await startService() }
    starting = task
    await task.value
    starting = nil
  }

  private func startService() async {
    do {
      let manager = FileManager.default
      let support = try manager.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
      let state = support.appending(path: "MunieHost/state", directoryHint: .isDirectory)
      guard let guardian = Bundle.main.url(forAuxiliaryExecutable: "MunieCodexGuardian") else {
        throw NativeRuntimeError.executableUnavailable
      }
      let runtime = NativeCodexRuntime(
        executable: URL(filePath: executable), guardian: guardian,
        codexHome: support.appending(path: "MunieHostCodex", directoryHint: .isDirectory),
        hostState: state)
      let source = manager.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
      let savedID = UserDefaults.standard.string(forKey: "hostID").flatMap(UUID.init(uuidString:))
      let id = savedID ?? UUID()
      UserDefaults.standard.set(id.uuidString, forKey: "hostID")
      UserDefaults.standard.set(executable, forKey: "nativeCodexPath")
      let name = Host.current().localizedName ?? "Mac"
      try await Task.detached {
        try FileManager.default.createDirectory(
          at: state.deletingLastPathComponent(),
          withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try runtime.prepare(usingLocalLoginAt: source)
      }.value
      let probe = try await Task.detached { try await runtime.adapter(for: support) }.value
      closeStartupProbe = { _ = try await probe.close() }
      try await closeStartupProbe?()
      closeStartupProbe = nil
      let notifications = try await Task.detached {
        try HostPushNotifications(
          configuration: HostPushNotifications.loadConfiguration(in: state))
      }.value
      push = notifications
      let created = try await Task.detached {
        try ProductHost(
          directoryURL: state, hostID: id, hostName: name, codexReady: true,
          adapterFactory: { directory in try await runtime.adapter(for: directory) },
          notificationSink: { device, task in await notifications.send(deviceID: device, task: task)
          })
      }.value
      host = created
      await notifications.bind(created)
      let listener = try HostHTTPServer(host: created)
      server = listener
      _ = try await listener.start()
      listening = true
      if stopping == nil { UserDefaults.standard.set(true, forKey: "serviceEnabled") }
      error = false
      await refresh()
    } catch {
      self.error = true
      _ = await closeResources()
    }
  }

  @discardableResult
  func stop(disableStartup: Bool = true) async -> Bool {
    if disableStartup { UserDefaults.standard.set(false, forKey: "serviceEnabled") }
    if let stopping { return await stopping.value }
    let task = Task {
      if let starting { await starting.value }
      return await closeResources()
    }
    stopping = task
    defer { stopping = nil }
    return await task.value
  }

  private func closeResources() async -> Bool {
    await server?.stop()
    listening = false
    invitation = nil
    invitationExpiresAt = nil
    candidate = nil
    do {
      try await closeStartupProbe?()
      closeStartupProbe = nil
      try await host?.close()
    } catch {
      cleanupFailed = true
      self.error = true
      return false
    }
    await push?.close()
    push = nil
    server = nil
    host = nil
    cleanupFailed = false
    return true
  }

  func refresh() async {
    guard let host else { return }
    status = await host.localStatus()
    candidate = await host.pendingPairing()
    devices = await host.devices()
    if let deadline = invitationExpiresAt, deadline <= Date() {
      invitation = nil
      invitationExpiresAt = nil
    }
  }

  func chooseProject() async {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let directory = panel.url, let host else { return }
    do {
      try await host.registerProject(
        id: UUID(), name: directory.lastPathComponent, directoryURL: directory)
      await refresh()
    } catch { self.error = true }
  }

  func pair() async {
    guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/", let host
    else {
      error = true
      return
    }
    do {
      invitation = try await host.startPairing(endpoint: url)
      invitationExpiresAt = Date().addingTimeInterval(120)
      UserDefaults.standard.set(endpoint, forKey: "hostEndpoint")
      await refresh()
    } catch { self.error = true }
  }

  func approve() async {
    guard let host, !selectedProjects.isEmpty else { return }
    do {
      try await host.approvePairing(projectIDs: selectedProjects)
      await refresh()
    } catch { self.error = true }
  }

  func reject() async {
    await host?.rejectPairing()
    invitation = nil
    await refresh()
  }

  func revoke(_ id: UUID) async {
    do {
      try await host?.revokeDevice(id: id)
      await refresh()
    } catch { self.error = true }
  }

  func deleteTask(_ id: UUID) async {
    do {
      try await host?.deleteTask(id: id)
      await refresh()
    } catch { self.error = true }
  }

  func loginItem() {
    do { try SMAppService.mainApp.register() } catch { self.error = true }
  }
}

struct HostView: View {
  @Bindable var controller: HostController
  @State private var taskToDelete: RemoteTask?

  var body: some View {
    Form {
      Section {
        Label(
          hostText(controller.serviceState),
          systemImage: controller.cleanupFailed
            ? "exclamationmark.triangle"
            : controller.listening ? "checkmark.circle" : "pause.circle")
        Text(
          hostText(
            "Keep this Mac awake and online. Closing this window keeps the service running; quitting stops it."
          )
        )
        .font(.callout).foregroundStyle(.secondary)
        DisclosureGroup(hostText("Advanced settings")) {
          TextField(hostText("Native Codex executable"), text: $controller.executable)
            .disabled(!controller.canStart)
        }
        HStack {
          Button(hostText("Start service")) { Task { await controller.start() } }
            .disabled(!controller.canStart)
          Button(hostText(controller.cleanupFailed ? "Retry stopping service" : "Stop service")) {
            Task { await controller.stop() }
          }
          .disabled((!controller.listening && !controller.cleanupFailed) || controller.busy)
          Button(hostText("Open at login")) { controller.loginItem() }
          Button(hostText("Refresh")) { Task { await controller.refresh() } }
        }
      } header: {
        Text(hostText("Mac connection"))
      }
      Section {
        ForEach(controller.status?.projects ?? []) { project in
          Toggle(
            project.name,
            isOn: Binding(
              get: { controller.selectedProjects.contains(project.id) },
              set: { selected in
                if selected {
                  controller.selectedProjects.insert(project.id)
                } else {
                  controller.selectedProjects.remove(project.id)
                }
              }))
        }
        Button(hostText("Authorize a project folder…")) {
          Task { await controller.chooseProject() }
        }
        .disabled(!controller.listening)
      } header: {
        Text(hostText("Projects for this iPhone"))
      }
      Section {
        TextField(hostText("Tailscale HTTPS address"), text: $controller.endpoint)
        Text(
          hostText(
            "Use Tailscale Serve on this Mac to proxy HTTPS to 127.0.0.1:9274. Pair only over your private tailnet."
          )
        )
        .font(.callout).foregroundStyle(.secondary)
        Button(hostText("Create pairing invitation")) { Task { await controller.pair() } }
          .disabled(!controller.listening || controller.selectedProjects.isEmpty)
        if let invitation = controller.invitation,
          let data = try? JSONEncoder().encode(invitation),
          let text = String(data: data, encoding: .utf8)
        {
          if let image = qrImage(data) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
              .frame(width: 180, height: 180).accessibilityHidden(true)
          }
          Text(hostText("Invitation expires after two minutes. Treat it as private."))
          DisclosureGroup(hostText("Manual pairing invitation")) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
          Button(hostText("Cancel pairing"), role: .cancel) { Task { await controller.reject() } }
        }
        if let candidate = controller.candidate {
          Text(candidate.name).font(.headline)
          Text(candidate.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(
            .enabled)
          Text(
            hostText(
              "Compare this fingerprint on your iPhone. Confirming grants access and control only to the selected projects."
            ))
          HStack {
            Button(hostText("Confirm this iPhone")) { Task { await controller.approve() } }
              .disabled(controller.selectedProjects.isEmpty)
            Button(hostText("Reject"), role: .destructive) { Task { await controller.reject() } }
          }
        }
      } header: {
        Text(hostText("Pair your iPhone"))
      }
      Section {
        ForEach(controller.devices, id: \.id) { device in
          HStack {
            Text(device.name)
            if !device.enabled { Text(hostText("Access revoked")).foregroundStyle(.secondary) }
            Spacer()
            Button(hostText("Revoke access"), role: .destructive) {
              Task { await controller.revoke(device.id) }
            }
            .disabled(!device.enabled)
          }
        }
      } header: {
        Text(hostText("Paired devices"))
      }
      Section {
        ForEach(controller.status?.tasks ?? []) { task in
          VStack(alignment: .leading) {
            Text(task.title)
            Text(String(localized: String.LocalizationValue(task.phase.rawValue), table: "Host"))
              .font(.caption).foregroundStyle(.secondary)
            if task.phase.isTerminal {
              Button(hostText("Remove Munie history…"), role: .destructive) { taskToDelete = task }
            }
          }
        }
      } header: {
        Text(hostText("Real Codex tasks"))
      }
      if controller.error {
        Text(
          hostText(
            "The operation failed. Check your local Codex login, executable, HTTPS address and service state, then try again."
          )
        )
        .foregroundStyle(.red).accessibilityAddTraits(.isStaticText)
      }
      if controller.cleanupFailed {
        Text(
          hostText(
            "The service has stopped accepting connections, but Codex cleanup is not confirmed. Retry stopping before restarting or quitting."
          )
        )
        .foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      hostText("Remove this task from Munie?"),
      isPresented: Binding(
        get: { taskToDelete != nil }, set: { if !$0 { taskToDelete = nil } }),
      presenting: taskToDelete
    ) { task in
      Button(hostText("Remove history"), role: .destructive) {
        Task { await controller.deleteTask(task.id) }
        taskToDelete = nil
      }
    } message: { _ in
      Text(
        hostText(
          "This removes Munie’s local conversation. Native Codex history remains on this Mac. Request identities stay reserved to prevent a deleted task from running again."
        ))
    }
    .task(id: controller.invitationExpiresAt) {
      // Only the two-minute pairing window polls. Idle Mac administration has no timer.
      while !Task.isCancelled, controller.invitationExpiresAt != nil {
        await controller.refresh()
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }

  private func qrImage(_ data: Data) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = data
    guard let output = filter.outputImage,
      let image = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(
      cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
  }
}

private func hostText(_ key: String.LocalizationValue) -> String {
  String(localized: key, table: "Host")
}
