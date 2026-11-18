import Foundation
import Observation

enum DesktopServiceState: Equatable {
  case stopped
  case starting
  case running
  case stopping
  case failed
  case cleanupUnconfirmed

  var title: String.LocalizationValue {
    switch self {
    case .stopped: "Mac service stopped"
    case .starting: "Starting Munie…"
    case .running: "Ready for your iPhone"
    case .stopping: "Stopping Munie…"
    case .failed: "Munie needs attention"
    case .cleanupUnconfirmed: "Stopping needs another try"
    }
  }
}

enum DesktopAccountState: Equatable {
  case unknown
  case signedOut
  case signingIn
  case signedIn
}

@MainActor @Observable
final class DesktopHostController {
  typealias RuntimeFactory = @Sendable () async throws -> any DesktopHostRuntime

  private(set) var serviceState: DesktopServiceState = .stopped
  private(set) var accountState: DesktopAccountState = .unknown
  private(set) var projectName = ""
  private(set) var deviceCount = 0
  private(set) var error: String.LocalizationValue?
  private(set) var accountBusy = false
  private(set) var projectBusy = false
  private(set) var loginURL: URL?

  var busy: Bool { starting != nil || stopping != nil }
  var canStart: Bool { runtime == nil && !busy }
  var canStop: Bool { runtime != nil && stopping == nil }
  var ready: Bool { serviceState == .running }

  @ObservationIgnored private let makeRuntime: RuntimeFactory
  @ObservationIgnored private let defaultProject: @Sendable () async throws -> URL
  @ObservationIgnored private var runtime: (any DesktopHostRuntime)?
  @ObservationIgnored private var starting: Task<Void, Never>?
  @ObservationIgnored private var stopping: Task<Bool, Never>?
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  init(
    makeRuntime: @escaping RuntimeFactory = {
      DesktopPackagedRuntime(configuration: try await .bundled())
    },
    defaultProject: @escaping @Sendable () async throws -> URL = {
      try await DesktopRuntimeConfiguration.bundled().defaultProject
    }
  ) {
    self.makeRuntime = makeRuntime
    self.defaultProject = defaultProject
  }

  func start() async {
    guard canStart else { return }
    serviceState = .starting
    error = nil
    let task = Task { await startService() }
    starting = task
    await task.value
    starting = nil
  }

  private func startService() async {
    do {
      let owned = try await makeRuntime()
      runtime = owned
      let activeGeneration = UUID()
      generation = activeGeneration
      let stream = try await owned.launch()
      eventTask = Task { [weak self] in
        for await event in stream {
          guard !Task.isCancelled else { break }
          self?.receive(event, generation: activeGeneration)
        }
      }
      let initial = try await owned.request("status", params: .object([:]))
      if initial["project"]?["path"]?.string == nil {
        let project = try await defaultProject()
        _ = try await owned.request(
          "project/set", params: .object(["path": .string(project.path)]))
      }
      let status = try await owned.request("start", params: .object([:]))
      apply(status)
      guard status["state"]?.string == "running" else {
        throw DesktopHostFailure.notRunning
      }
      // A stop requested during startup owns the next transition.
      if stopping == nil {
        serviceState = .running
        await refreshAccount(using: owned)
      }
    } catch {
      if await closeResources() {
        serviceState = .failed
        self.error =
          (error as? DesktopHostControlError)?.code == "network_unavailable"
          ? "Connect this Mac to Wi-Fi or Ethernet, then try again."
          : "Munie could not start. Try again."
      }
    }
  }

  /// Coalesces callers and waits for startup ownership to settle before cleanup.
  @discardableResult
  func stop() async -> Bool {
    if let stopping { return await stopping.value }
    serviceState = .stopping
    let task = Task {
      if let starting { await starting.value }
      return await closeResources()
    }
    stopping = task
    defer { stopping = nil }
    return await task.value
  }

  private func closeResources() async -> Bool {
    do {
      try await runtime?.shutdown()
    } catch {
      serviceState = .cleanupUnconfirmed
      self.error = "Munie could not confirm that all work stopped. Retry before quitting."
      return false
    }
    eventTask?.cancel()
    eventTask = nil
    generation = UUID()
    runtime = nil
    serviceState = .stopped
    accountBusy = false
    projectBusy = false
    loginURL = nil
    error = nil
    return true
  }

  func refresh() async {
    guard ready, let runtime else { return }
    let operationGeneration = generation
    do {
      let status = try await runtime.request("status", params: .object([:]))
      guard operationGeneration == generation else { return }
      apply(status)
      await refreshAccount(using: runtime)
    } catch {
      guard operationGeneration == generation else { return }
      self.error = "Munie could not refresh its status. Try again."
    }
  }

  func beginLogin() async -> URL? {
    guard ready, !accountBusy, let runtime else { return nil }
    let operationGeneration = generation
    accountBusy = true
    defer { if operationGeneration == generation { accountBusy = false } }
    do {
      let result = try await runtime.request("account/login/start", params: .object([:]))
      guard operationGeneration == generation else { return nil }
      guard let value = result["authUrl"]?.string else {
        throw DesktopHostFailure.loginURLRejected
      }
      let url = try DesktopLoginURL.validated(value)
      loginURL = url
      accountState = .signingIn
      error = nil
      return url
    } catch {
      guard operationGeneration == generation else { return nil }
      self.error = "Sign-in could not start. Try again."
      return nil
    }
  }

  func cancelLogin() async {
    guard ready, !accountBusy, let runtime else { return }
    let operationGeneration = generation
    accountBusy = true
    defer { if operationGeneration == generation { accountBusy = false } }
    do {
      _ = try await runtime.request("account/login/cancel", params: .object([:]))
      guard operationGeneration == generation else { return }
      loginURL = nil
      accountState = .signedOut
      error = nil
    } catch {
      guard operationGeneration == generation else { return }
      self.error = "Sign-in could not be cancelled. Try again."
    }
  }

  func setProject(_ url: URL) async {
    guard ready, !projectBusy, url.isFileURL, let runtime else { return }
    let operationGeneration = generation
    projectBusy = true
    defer { if operationGeneration == generation { projectBusy = false } }
    do {
      let result = try await runtime.request(
        "project/set", params: .object(["path": .string(url.path)]))
      guard operationGeneration == generation else { return }
      apply(result)
      error = nil
    } catch {
      guard operationGeneration == generation else { return }
      self.error = "This project could not be selected. Try another folder."
    }
  }

  /// Called only from the explicit Mac confirmation action, never while advertising.
  func pairingPayload() async throws -> Data {
    guard ready, let runtime else { throw DesktopHostFailure.notRunning }
    let operationGeneration = generation
    let result = try await runtime.request("pairing/get", params: .object([:]))
    guard operationGeneration == generation, ready else { throw DesktopHostFailure.notRunning }
    guard let payload = result["payload"] else {
      throw DesktopHostFailure.invalidProtocol
    }
    let data = try JSONEncoder().encode(payload)
    guard data.count <= 32_768 else { throw DesktopHostFailure.oversizedFrame }
    return data
  }

  func pairingFailed() {
    error = "Pairing did not finish. Keep both apps open and try again."
  }

  func loginBrowserFailed() {
    error = "The sign-in page could not open. Try opening it again."
  }

  private func refreshAccount(using runtime: any DesktopHostRuntime) async {
    let operationGeneration = generation
    do {
      let account = try await runtime.request("account/read", params: .object([:]))
      guard operationGeneration == generation else { return }
      apply(.object(["account": account]))
    } catch {
      guard operationGeneration == generation else { return }
      self.error = "Account status is unavailable. You can try signing in again."
    }
  }

  private func receive(_ event: DesktopHostEvent, generation: UUID) {
    guard generation == self.generation else { return }
    switch event {
    case .message(let name, let data):
      if name == "status" { apply(data) }
      if name == "account" { apply(.object(["account": data["account"] ?? data])) }
    case .exited:
      guard serviceState != .stopping, serviceState != .stopped else { return }
      serviceState = .cleanupUnconfirmed
      error = "Munie stopped unexpectedly. Cleanup must be confirmed before restarting."
    case .protocolFailure:
      serviceState = .cleanupUnconfirmed
      error = "Munie lost its local connection. Retry stopping before restarting."
    }
  }

  private func apply(_ value: DesktopJSON) {
    let state = value["state"]?.string
    if state == "error", serviceState != .stopping {
      serviceState = .cleanupUnconfirmed
      error = "Munie lost its local connection. Retry stopping before restarting."
    } else if starting == nil, stopping == nil {
      switch state {
      case "starting": serviceState = .starting
      case "running": serviceState = .running
      case "stopping": serviceState = .stopping
      case "stopped": serviceState = .stopped
      default: break
      }
    }
    if let project = value["project"]?["name"]?.string { projectName = project }
    if let devices = value["devices"]?.array { deviceCount = devices.count }
    if let account = value["account"] {
      if account["status"]?.string == "authenticated" {
        accountState = .signedIn
        loginURL = nil
      } else if account["status"]?.string == "pending_login" {
        accountState = .signingIn
      } else {
        accountState = .signedOut
      }
    }
  }
}
