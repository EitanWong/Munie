import AppKit
import MunieNearby
import Observation

@MainActor @Observable
final class DesktopCoordinator {
  let controller = DesktopHostController()
  @ObservationIgnored let nearby = NearbyPairingHost()
  private(set) var pairingBusy = false
  private(set) var nearbyFailed = false
  @ObservationIgnored private var didLaunch = false

  func startOnFirstLaunch() async {
    guard !didLaunch else { return }
    didLaunch = true
    await start()
  }

  func start() async {
    await controller.start()
    updateNearbyAvailability()
  }

  @discardableResult
  func stop() async -> Bool {
    nearby.stop()
    return await controller.stop()
  }

  func updateNearbyAvailability() {
    guard controller.ready else {
      nearby.stop()
      return
    }
    guard nearby.state == .idle || nearby.state == .failed || nearbyFailed else { return }
    do {
      try nearby.start(hostName: Host.current().localizedName ?? "Mac")
      nearbyFailed = false
    } catch {
      nearbyFailed = true
    }
  }

  func approvePairing(_ id: UUID) async {
    guard !pairingBusy, nearby.pendingRequest?.id == id else { return }
    pairingBusy = true
    defer { pairingBusy = false }
    do {
      // Obtain the bootstrap only inside this explicit confirmation action.
      let payload = try await controller.pairingPayload()
      guard nearby.pendingRequest?.id == id, controller.ready else { return }
      try nearby.approve(requestID: id, payload: payload)
    } catch {
      controller.pairingFailed()
    }
  }

  func rejectPairing(_ id: UUID) {
    nearby.reject(requestID: id)
  }

  func chooseProject() async {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Use Project", table: "Desktop")
    panel.message = String(
      localized: "Changing projects restarts the Mac service and may stop active work.",
      table: "Desktop")
    let response = await withCheckedContinuation { continuation in
      panel.begin { response in continuation.resume(returning: response) }
    }
    guard response == .OK, let directory = panel.url else { return }
    await controller.setProject(directory)
  }

  func signIn() async {
    guard let url = await controller.beginLogin() else { return }
    openLogin(url)
  }

  func reopenLogin() {
    guard let url = controller.loginURL else { return }
    openLogin(url)
  }

  private func openLogin(_ url: URL) {
    if !NSWorkspace.shared.open(url) { controller.loginBrowserFailed() }
  }
}
