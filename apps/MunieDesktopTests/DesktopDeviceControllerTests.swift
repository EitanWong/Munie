import Foundation
import Testing

@testable import MunieDesktop

@MainActor
struct DesktopDeviceControllerTests {
  @Test func projectReplyCannotRestoreAnOlderLANBinding() async {
    let runtime = DesktopDeviceRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    #expect(controller.nearbyReady)
    await runtime.blockNextProject()
    let change = Task { await controller.setProject(URL(filePath: "/fixture/Next")) }
    await runtime.waitForRequest("project/set")
    await runtime.emitStatus(deviceStatus(["phone-A"], lanRevision: 2, lanAvailable: false))
    await waitUntil { !controller.nearbyReady }
    await runtime.completeProject(deviceStatus(["phone-A"]))
    await change.value
    #expect(controller.ready)
    #expect(!controller.nearbyReady)
    #expect(await controller.stop())
  }

  @Test func revokeRequiresCurrentExactIDAndAppliesActualReturnedList() async {
    let runtime = DesktopDeviceRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    #expect(controller.pairedDevices == [DesktopPairedDevice(id: "phone-A")])
    for value in ["phone", "phone-a", "phone-A ", "fingerprint"] {
      await controller.revokePairing(deviceID: value)
    }
    #expect(await runtime.revokeParameters.isEmpty)
    let revoke = Task { await controller.revokePairing(deviceID: "phone-A") }
    await runtime.waitForRequest("devices/revoke")
    #expect(controller.deviceBusy)
    #expect(controller.pairedDevices.map(\.id) == ["phone-A"])
    await controller.revokePairing(deviceID: "phone-A")
    #expect(await runtime.revokeParameters == [.object(["deviceId": .string("phone-A")])])
    await runtime.completeRevoke(.success(deviceStatus(["phone-B"])))
    await revoke.value
    #expect(controller.pairedDevices.map(\.id) == ["phone-B"])
    #expect(!controller.deviceBusy)
    #expect(controller.error == nil)
    // The confirmation's former target must not resolve to a different current phone.
    await controller.revokePairing(deviceID: "phone-A")
    #expect(await runtime.revokeParameters.count == 1)
    #expect(await controller.stop())
  }

  @Test func failedRevokeRetainsLatestActualListIncludingResetBeforeRestartFailure() async {
    let runtime = DesktopDeviceRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    let first = Task { await controller.revokePairing(deviceID: "phone-A") }
    await runtime.waitForRequest("devices/revoke")
    await runtime.completeRevoke(.failure(.notRunning))
    await first.value
    #expect(controller.pairedDevices.map(\.id) == ["phone-A"])
    #expect(controller.error != nil)

    let second = Task { await controller.revokePairing(deviceID: "phone-A") }
    await runtime.waitForRequest("devices/revoke", count: 2)
    await runtime.emitStatus(deviceStatus([], state: "stopped"))
    await waitUntil { controller.pairedDevices.isEmpty }
    await runtime.completeRevoke(.failure(.notRunning))
    await second.value
    #expect(controller.pairedDevices.isEmpty)
    #expect(controller.error != nil)
    #expect(!controller.deviceBusy)
    #expect(await controller.stop())
  }

  @Test func refreshStartedBeforeRevokeCannotRestoreItsOldSnapshot() async {
    let runtime = DesktopDeviceRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    await runtime.blockNextStatus()
    let refresh = Task { await controller.refresh() }
    await runtime.waitForRequest("status", count: 2)
    let revoke = Task { await controller.revokePairing(deviceID: "phone-A") }
    await runtime.waitForRequest("devices/revoke")
    await runtime.completeRevoke(.success(deviceStatus([])))
    await revoke.value
    await runtime.completeStatus(deviceStatus(["phone-A"]))
    await refresh.value
    #expect(controller.pairedDevices.isEmpty)
    #expect(controller.error == nil)
    #expect(await controller.stop())
  }

  @Test func failedRevokeReadsActualStatusWhenResetHadNoDeliveredEvent() async {
    let runtime = DesktopDeviceRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    let revoke = Task { await controller.revokePairing(deviceID: "phone-A") }
    await runtime.waitForRequest("devices/revoke")
    await runtime.setDevices([])
    await runtime.completeRevoke(.failure(.notRunning))
    await revoke.value
    #expect(controller.pairedDevices.isEmpty)
    #expect(controller.error != nil)
    #expect(!controller.deviceBusy)
    #expect(await controller.stop())
  }

  @Test(arguments: [true, false])
  func failedStopKeepsOwnershipAndErrorDespiteLateRevoke(success: Bool) async {
    let runtime = DesktopDeviceRuntimeFixture(stopFailures: 1)
    let controller = makeController(runtime)
    await controller.start()
    let revoke = Task { await controller.revokePairing(deviceID: "phone-A") }
    await runtime.waitForRequest("devices/revoke")
    #expect(await controller.stop() == false)
    let stopError = controller.error
    #expect(controller.serviceState == .cleanupUnconfirmed)
    await runtime.completeRevoke(
      success ? .success(deviceStatus([])) : .failure(.notRunning))
    await revoke.value
    #expect(controller.serviceState == .cleanupUnconfirmed)
    #expect(controller.error == stopError)
    #expect(!controller.canStart)
    #expect(controller.pairedDevices.map(\.id) == ["phone-A"])
    // A delayed helper status must also leave the native cleanup gate intact.
    await runtime.emitStatus(deviceStatus(["phone-B"]))
    await waitUntil { controller.pairedDevices.map(\.id) == ["phone-B"] }
    #expect(controller.serviceState == .cleanupUnconfirmed)
    #expect(controller.error == stopError)
    #expect(await controller.stop())
  }

  @Test func oldRevokeCannotChangeRestartedController() async {
    let runtime = DesktopDeviceRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    let revoke = Task { await controller.revokePairing(deviceID: "phone-A") }
    await runtime.waitForRequest("devices/revoke")
    #expect(await controller.stop())
    await runtime.setDevices(["phone-B"])
    await controller.start()
    await runtime.completeRevoke(.success(deviceStatus([])))
    await revoke.value
    #expect(controller.pairedDevices.map(\.id) == ["phone-B"])
    #expect(controller.serviceState == .running)
    #expect(controller.error == nil)
    #expect(await controller.stop())
  }

  @Test func pairingPayloadStartedBeforeRevokeCannotEscapeAfterServiceRestarts() async {
    let runtime = DesktopDeviceRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    let pairing = Task {
      await #expect(throws: DesktopHostFailure.notRunning) {
        try await controller.pairingPayload()
      }
    }
    await runtime.waitForRequest("pairing/get")
    let revoke = Task { await controller.revokePairing(deviceID: "phone-A") }
    await runtime.waitForRequest("devices/revoke")
    await runtime.completeRevoke(.success(deviceStatus([])))
    await revoke.value
    #expect(controller.ready)
    await runtime.completePairing()
    _ = await pairing.value
    #expect(await controller.stop())
  }

  @Test(arguments: [
    DesktopJSON.null,
    .array([.object(["id": .string("phone-B")]), .object([:])]),
    .array([.object(["id": .string("")])]),
    .array([.object(["id": .string("phone-B")]), .object(["id": .string("phone-B")])]),
  ])
  func malformedDeviceListsDoNotInventAnEmptyOrPartialPairingState(records: DesktopJSON) async {
    let runtime = DesktopDeviceRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    await runtime.emitStatus(.object(["devices": records]))
    await waitUntil { controller.error != nil }
    #expect(controller.pairedDevices.map(\.id) == ["phone-A"])
    #expect(await controller.stop())
  }

  private func makeController(_ runtime: DesktopDeviceRuntimeFixture) -> DesktopHostController {
    DesktopHostController(
      makeRuntime: { runtime },
      defaultProject: { URL(filePath: "/fixture/Project", directoryHint: .isDirectory) },
      providerStore: DesktopProviderStoreFixture())
  }

  private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    #expect(condition())
  }
}

private func deviceStatus(
  _ ids: [String], state: String = "running", lanRevision: Double = 1, lanAvailable: Bool? = nil
) -> DesktopJSON {
  .object([
    "state": .string(state),
    "lanAvailable": .bool(lanAvailable ?? (state == "running")),
    "lanRevision": .number(lanRevision),
    "project": .object(["path": .string("/fixture/Project"), "name": .string("Project")]),
    "devices": .array(ids.map { .object(["id": .string($0), "fingerprint": .string("fixture")]) }),
  ])
}

private actor DesktopDeviceRuntimeFixture: DesktopHostRuntime {
  private(set) var revokeParameters: [DesktopJSON] = []
  private var requests: [String] = []
  private var waiters: [(String, Int, CheckedContinuation<Void, Never>)] = []
  private var devices = ["phone-A"]
  private var events: AsyncStream<DesktopHostEvent>.Continuation?
  private var revoke: CheckedContinuation<DesktopJSON, any Error>?
  private var status: CheckedContinuation<DesktopJSON, Never>?
  private var pairing: CheckedContinuation<DesktopJSON, Never>?
  private var project: CheckedContinuation<DesktopJSON, Never>?
  private var shouldBlockStatus = false
  private var shouldBlockProject = false
  private var stopFailures: Int

  init(stopFailures: Int = 0) { self.stopFailures = stopFailures }

  func launch() -> AsyncStream<DesktopHostEvent> {
    let (stream, continuation) = AsyncStream<DesktopHostEvent>.makeStream()
    events = continuation
    return stream
  }

  func request(_ method: String, params: DesktopJSON) async throws -> DesktopJSON {
    requests.append(method)
    if method == "devices/revoke" {
      revokeParameters.append(params)
      return try await withCheckedThrowingContinuation { continuation in
        revoke = continuation
        notifyWaiters()
      }
    }
    if method == "status", shouldBlockStatus {
      shouldBlockStatus = false
      return await withCheckedContinuation { continuation in
        status = continuation
        notifyWaiters()
      }
    }
    if method == "pairing/get" {
      return await withCheckedContinuation { continuation in
        pairing = continuation
        notifyWaiters()
      }
    }
    if method == "project/set", shouldBlockProject {
      shouldBlockProject = false
      return await withCheckedContinuation { continuation in
        project = continuation
        notifyWaiters()
      }
    }
    notifyWaiters()
    if method == "account/read" { return .object(["status": .string("not_authenticated")]) }
    return deviceStatus(devices)
  }

  func shutdown() throws {
    if stopFailures > 0 {
      stopFailures -= 1
      throw DesktopHostFailure.cleanupUnconfirmed
    }
    events?.finish()
    events = nil
  }

  func setDevices(_ ids: [String]) { devices = ids }
  func blockNextStatus() { shouldBlockStatus = true }
  func blockNextProject() { shouldBlockProject = true }
  func emitStatus(_ status: DesktopJSON) {
    if let records = status["devices"]?.array {
      let ids = records.compactMap { $0["id"]?.string }
      if ids.count == records.count { devices = ids }
    }
    events?.yield(.message(name: "status", data: status))
  }

  func completeRevoke(_ result: Result<DesktopJSON, DesktopHostFailure>) {
    revoke?.resume(with: result.mapError { $0 as any Error })
    revoke = nil
  }

  func completeStatus(_ result: DesktopJSON) {
    status?.resume(returning: result)
    status = nil
  }

  func completePairing() {
    pairing?.resume(returning: .object(["payload": .object(["v": .number(2)])]))
    pairing = nil
  }

  func completeProject(_ result: DesktopJSON) {
    project?.resume(returning: result)
    project = nil
  }

  func waitForRequest(_ method: String, count: Int = 1) async {
    if requests.filter({ $0 == method }).count >= count { return }
    await withCheckedContinuation { waiters.append((method, count, $0)) }
  }

  private func notifyWaiters() {
    var remaining: [(String, Int, CheckedContinuation<Void, Never>)] = []
    for waiter in waiters {
      if requests.filter({ $0 == waiter.0 }).count >= waiter.1 {
        waiter.2.resume()
      } else {
        remaining.append(waiter)
      }
    }
    waiters = remaining
  }
}
