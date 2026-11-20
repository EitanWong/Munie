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

enum DesktopModelProvider: Equatable {
  case unknown
  case chatGPT
  case openAIAPIKey
}

struct DesktopPairedDevice: Equatable, Sendable, Identifiable {
  let id: String
}

@MainActor @Observable
final class DesktopHostController {
  typealias RuntimeFactory = @Sendable () async throws -> any DesktopHostRuntime

  private(set) var serviceState: DesktopServiceState = .stopped {
    didSet {
      if lanAvailable && (oldValue == .running) != ready { onNearbyAvailabilityChange?() }
    }
  }
  private(set) var lanAvailable = false {
    didSet {
      if ready && oldValue != lanAvailable { onNearbyAvailabilityChange?() }
    }
  }
  private(set) var accountState: DesktopAccountState = .unknown
  private(set) var modelProvider: DesktopModelProvider = .unknown
  private(set) var changingModelProvider = false
  private(set) var modelProviderError: String.LocalizationValue?
  private(set) var projectName = ""
  private(set) var pairedDevices: [DesktopPairedDevice] = []
  private(set) var hasPairingStatus = false
  private(set) var revokingDeviceID: String?
  private(set) var error: String.LocalizationValue?
  private(set) var accountBusy = false
  private(set) var projectBusy = false
  private(set) var loginURL: URL?

  var busy: Bool { starting != nil || stopping != nil }
  var canStart: Bool { runtime == nil && !busy && !changingModelProvider }
  var canChangeModelProvider: Bool {
    canStart && (serviceState == .stopped || serviceState == .failed)
  }
  var canStop: Bool { runtime != nil && stopping == nil }
  var ready: Bool { serviceState == .running }
  var nearbyReady: Bool { ready && lanAvailable }
  var statusTitle: String.LocalizationValue {
    ready && !lanAvailable ? "Waiting for a local network" : serviceState.title
  }
  var deviceCount: Int { pairedDevices.count }
  var deviceBusy: Bool { revokingDeviceID != nil }
  var canRemovePairing: Bool {
    ready && !busy && !projectBusy && !deviceBusy && !pairedDevices.isEmpty
  }

  @ObservationIgnored private let makeRuntime: RuntimeFactory
  @ObservationIgnored private let defaultProject: @Sendable () async throws -> URL
  @ObservationIgnored private let openAIKeyStore: any DesktopOpenAIKeyStore
  @ObservationIgnored var onNearbyAvailabilityChange: (() -> Void)?
  // These handles also drive the observable start, stop and busy controls.
  private var runtime: (any DesktopHostRuntime)?
  private var starting: Task<Void, Never>?
  private var stopping: Task<Bool, Never>?
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var statusRevision = UUID()
  @ObservationIgnored private var latestLANRevision: UInt64?
  @ObservationIgnored private var deviceOperation: UUID?

  init(
    makeRuntime: @escaping RuntimeFactory = {
      DesktopPackagedRuntime(configuration: try await .bundled())
    },
    defaultProject: @escaping @Sendable () async throws -> URL = {
      try await DesktopRuntimeConfiguration.bundled().defaultProject
    },
    openAIKeyStore: any DesktopOpenAIKeyStore
  ) {
    self.makeRuntime = makeRuntime
    self.defaultProject = defaultProject
    self.openAIKeyStore = openAIKeyStore
  }

  func start() async {
    guard canStart else { return }
    serviceState = .starting
    error = nil
    accountState = .unknown
    let task = Task { await startService() }
    starting = task
    await task.value
    starting = nil
  }

  private func startService() async {
    do {
      let apiKey: DesktopOpenAIKey?
      do {
        apiKey = try await openAIKeyStore.read()
        modelProvider = apiKey == nil ? .chatGPT : .openAIAPIKey
        modelProviderError = nil
      } catch {
        modelProviderError = "Munie could not read the API key from the Keychain."
        throw DesktopOpenAIKeyStoreFailure.unavailable
      }
      guard stopping == nil else { return }
      let owned = try await makeRuntime()
      runtime = owned
      let activeGeneration = UUID()
      generation = activeGeneration
      latestLANRevision = nil
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
      guard stopping == nil else { return }
      let params: DesktopJSON = .object(apiKey.map { ["apiKey": .string($0.value)] } ?? [:])
      let status = try await owned.request("start", params: params)
      apply(status)
      guard status["state"]?.string == "running" else {
        throw DesktopHostFailure.notRunning
      }
      // A stop requested during startup owns the next transition.
      if stopping == nil {
        serviceState = .running
        if modelProvider != .openAIAPIKey { await refreshAccount(using: owned) }
      }
    } catch {
      if await closeResources() {
        serviceState = .failed
        switch (error as? DesktopHostControlError)?.code {
        case "network_unavailable":
          self.error = "Connect this Mac to Wi-Fi or Ethernet, then try again."
        case "api_key_unavailable":
          modelProviderError = "Munie could not load the official API key into Codex."
        default:
          if !(error is DesktopOpenAIKeyStoreFailure) {
            self.error = "Munie could not start. Try again."
          }
        }
      }
    }
  }

  @discardableResult
  func saveOpenAIAPIKey(_ value: String) async -> Bool {
    guard canChangeModelProvider else { return false }
    guard let key = DesktopOpenAIKey(validating: value) else {
      modelProviderError = "Enter an API key without spaces or line breaks."
      return false
    }
    return await changeModelProvider(to: key)
  }

  @discardableResult
  func removeOpenAIAPIKey() async -> Bool {
    guard canChangeModelProvider else { return false }
    return await changeModelProvider(to: nil)
  }

  private func changeModelProvider(to key: DesktopOpenAIKey?) async -> Bool {
    changingModelProvider = true
    modelProviderError = nil
    defer { changingModelProvider = false }
    do {
      if let key {
        try await openAIKeyStore.save(key)
        modelProvider = .openAIAPIKey
      } else {
        try await openAIKeyStore.remove()
        modelProvider = .chatGPT
      }
      accountState = .unknown
      loginURL = nil
      return true
    } catch {
      // Do not show or retain an error's payload, which may contain credential data.
      modelProviderError = "Munie could not update the API key in the Keychain."
      return false
    }
  }

  /// Coalesces callers and waits for startup ownership to settle before cleanup.
  @discardableResult
  func stop() async -> Bool {
    // The quit path must not abandon an active Keychain update.
    guard !changingModelProvider else { return false }
    if let stopping { return await stopping.value }
    invalidateDeviceOperation()
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
    invalidateDeviceOperation()
    runtime = nil
    serviceState = .stopped
    lanAvailable = false
    accountBusy = false
    projectBusy = false
    loginURL = nil
    error = nil
    return true
  }

  func refresh() async {
    guard ready, !busy, !deviceBusy, !projectBusy, let runtime else { return }
    let operationGeneration = generation
    let revision = statusRevision
    do {
      let status = try await runtime.request("status", params: .object([:]))
      guard operationGeneration == generation, revision == statusRevision else { return }
      apply(status)
      if modelProvider != .openAIAPIKey { await refreshAccount(using: runtime) }
    } catch {
      guard operationGeneration == generation, revision == statusRevision else { return }
      self.error = "Munie could not refresh its status. Try again."
    }
  }

  func beginLogin() async -> URL? {
    guard ready, modelProvider != .openAIAPIKey, !accountBusy, let runtime else { return nil }
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
    guard ready, modelProvider != .openAIAPIKey, !accountBusy, let runtime else { return }
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
    guard ready, !busy, !projectBusy, !deviceBusy, url.isFileURL, let runtime else { return }
    let operationGeneration = generation
    statusRevision = UUID()
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

  /// The helper currently resets the single supported phone pairing and restarts its service.
  /// Keep the exact local target check even if the confirmation was opened before a status change.
  func revokePairing(deviceID: String) async {
    guard ready, !busy, !projectBusy, !deviceBusy, let runtime else { return }
    guard pairedDevices.contains(where: { $0.id == deviceID }) else {
      error = "This iPhone is no longer paired. Refresh to see the current pairing."
      return
    }
    let operationGeneration = generation
    let operation = UUID()
    deviceOperation = operation
    revokingDeviceID = deviceID
    statusRevision = UUID()
    defer {
      if operationGeneration == generation, deviceOperation == operation {
        deviceOperation = nil
        revokingDeviceID = nil
        statusRevision = UUID()
      }
    }
    do {
      let status = try await runtime.request(
        "devices/revoke", params: .object(["deviceId": .string(deviceID)]))
      guard operationGeneration == generation, deviceOperation == operation else { return }
      guard status["devices"] != nil else { throw DesktopHostFailure.invalidProtocol }
      if apply(status), serviceState != .cleanupUnconfirmed { error = nil }
    } catch {
      guard operationGeneration == generation, deviceOperation == operation else { return }
      // Status events can already reflect a completed reset even if the restart failed.
      // Retain that latest actual list rather than restoring a pre-request snapshot.
      let revision = statusRevision
      do {
        let status = try await runtime.request("status", params: .object([:]))
        guard operationGeneration == generation, deviceOperation == operation else { return }
        if revision == statusRevision { apply(status) }
      } catch {
        guard operationGeneration == generation, deviceOperation == operation else { return }
      }
      if serviceState != .cleanupUnconfirmed {
        self.error =
          "Pairing removal could not finish. Stop Munie, then start it again to check the pairing."
      }
    }
  }

  /// Called only from the explicit Mac confirmation action, never while advertising.
  func pairingPayload() async throws -> Data {
    guard nearbyReady, !deviceBusy, !projectBusy, let runtime else {
      throw DesktopHostFailure.notRunning
    }
    let operationGeneration = generation
    let revision = statusRevision
    let result = try await runtime.request("pairing/get", params: .object([:]))
    guard operationGeneration == generation, revision == statusRevision,
      nearbyReady, !busy, !deviceBusy, !projectBusy
    else { throw DesktopHostFailure.notRunning }
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
      if name == "status" {
        statusRevision = UUID()
        apply(data)
      }
      if name == "account" { apply(.object(["account": data["account"] ?? data])) }
    case .exited:
      guard serviceState != .stopping, serviceState != .stopped else { return }
      invalidateDeviceOperation()
      serviceState = .cleanupUnconfirmed
      error = "Munie stopped unexpectedly. Cleanup must be confirmed before restarting."
    case .protocolFailure:
      invalidateDeviceOperation()
      serviceState = .cleanupUnconfirmed
      error = "Munie lost its local connection. Retry stopping before restarting."
    }
  }

  private func invalidateDeviceOperation() {
    deviceOperation = nil
    revokingDeviceID = nil
    statusRevision = UUID()
  }

  @discardableResult
  private func apply(_ value: DesktopJSON) -> Bool {
    // Replies and events arrive on separate paths even though the helper writes them in order.
    if let available = value["lanAvailable"]?.boolean,
      case .number(let rawRevision)? = value["lanRevision"], rawRevision <= 9_007_199_254_740_991,
      let revision = UInt64(exactly: rawRevision)
    {
      if let latestLANRevision, revision < latestLANRevision { return false }
      if revision != latestLANRevision {
        latestLANRevision = revision
        lanAvailable = available
      }
    }
    if let records = value["devices"] {
      guard let records = records.array else {
        error = "The paired iPhone status is unavailable. Try refreshing."
        return false
      }
      let ids = records.compactMap { $0["id"]?.string }
      guard ids.count == records.count, ids.allSatisfy({ !$0.isEmpty }),
        Set(ids).count == ids.count
      else {
        error = "The paired iPhone status is unavailable. Try refreshing."
        return false
      }
      pairedDevices = ids.map { DesktopPairedDevice(id: $0) }
      hasPairingStatus = true
    }
    let state = value["state"]?.string
    if state == "error", serviceState != .stopping {
      serviceState = .cleanupUnconfirmed
      error = "Munie lost its local connection. Retry stopping before restarting."
    } else if starting == nil, stopping == nil, serviceState != .cleanupUnconfirmed {
      switch state {
      case "starting": serviceState = .starting
      case "running": serviceState = .running
      case "stopping": serviceState = .stopping
      case "stopped": serviceState = .stopped
      default: break
      }
    }
    if let project = value["project"]?["name"]?.string { projectName = project }
    if modelProvider != .openAIAPIKey, let account = value["account"] {
      if account["status"]?.string == "authenticated" {
        accountState = .signedIn
        loginURL = nil
      } else if account["status"]?.string == "pending_login" {
        accountState = .signingIn
      } else {
        accountState = .signedOut
      }
    }
    return true
  }
}
