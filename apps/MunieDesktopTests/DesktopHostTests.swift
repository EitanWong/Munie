import Darwin
import Foundation
import Observation
import Testing

@testable import MunieDesktop

struct DesktopInstanceLockTests {
  @Test func secondOpenCannotOwnTheSlotUntilFirstReleasesIt() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
      let acquired = try DesktopInstanceLock.acquire(in: directory)
      let first = try #require(acquired)
      try withExtendedLifetime(first) {
        let contender = try DesktopInstanceLock.acquire(in: directory)
        #expect(contender == nil)
      }
    }

    let reacquired = try DesktopInstanceLock.acquire(in: directory)
    let next = try #require(reacquired)
    try withExtendedLifetime(next) {
      let contender = try DesktopInstanceLock.acquire(in: directory)
      #expect(contender == nil)
    }
  }

  @Test func refusesSymlinkWithoutChangingItsTarget() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "unrelated")
    let bytes = Data("unchanged".utf8)
    try bytes.write(to: target)
    try FileManager.default.createSymbolicLink(
      at: directory.appending(path: ".desktop-instance.lock"), withDestinationURL: target)

    #expect(throws: POSIXError.self) { try DesktopInstanceLock.acquire(in: directory) }
    #expect(try Data(contentsOf: target) == bytes)
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }
}

@MainActor
struct DesktopHostLifecycleTests {
  @Test func controlsObserveBusyClearingAfterStartup() async {
    let runtime = DesktopRuntimeFixture(blockStart: true)
    let controller = makeController(runtime)
    let start = Task { await controller.start() }
    await runtime.waitUntilStartRequested()
    await confirmation("The observed busy state invalidates when startup finishes") { changed in
      withObservationTracking {
        #expect(controller.busy)
      } onChange: {
        changed()
      }
      await runtime.releaseStart()
      await start.value
      #expect(!controller.busy)
      #expect(controller.canStop)
    }
    #expect(await controller.stop())
  }

  @Test func controlsObserveAvailabilityAfterStop() async {
    let runtime = DesktopRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    await confirmation("The observed start control invalidates when ownership clears") { changed in
      withObservationTracking {
        #expect(!controller.canStart)
      } onChange: {
        changed()
      }
      #expect(await controller.stop())
      #expect(controller.canStart)
    }
  }

  @Test func localNetworkAvailabilityChangesWithoutRestartingTheRuntime() async {
    let runtime = DesktopRuntimeFixture()
    let controller = makeController(runtime)
    var advertised: [Bool] = []
    let (changes, output) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(4))
    defer { output.finish() }
    controller.onNearbyAvailabilityChange = { [weak controller] in
      if let controller {
        output.yield(controller.nearbyReady)
        advertised.append(controller.nearbyReady)
      }
    }
    var events = changes.makeAsyncIterator()

    await controller.start()
    #expect(await events.next() == true)
    await runtime.emit(
      .message(
        name: "status",
        data: .object([
          "lanAvailable": .bool(false), "lanRevision": .number(2),
        ])))
    #expect(await events.next() == false)
    #expect(controller.ready)
    await #expect(throws: DesktopHostFailure.notRunning) { try await controller.pairingPayload() }
    await runtime.emit(
      .message(
        name: "status",
        data: .object([
          "lanAvailable": .bool(true), "lanRevision": .number(3),
        ])))
    #expect(await events.next() == true)
    #expect(await runtime.launchCount == 1)
    #expect(await runtime.stopCount == 0)
    #expect(await controller.stop())
    #expect(advertised == [true, false, true, false])
  }

  @Test func stopFailureRetainsOwnershipUntilRetryConfirmsCleanup() async {
    let runtime = DesktopRuntimeFixture(stopFailures: 1)
    let controller = makeController(runtime)
    await controller.start()
    #expect(controller.serviceState == .running)
    #expect(await controller.stop() == false)
    #expect(controller.serviceState == .cleanupUnconfirmed)
    #expect(controller.canStart == false)
    #expect(controller.canStop)
    await controller.start()
    #expect(await runtime.launchCount == 1)
    #expect(await controller.stop())
    #expect(controller.serviceState == .stopped)
    #expect(controller.canStart)
    #expect(await runtime.stopCount == 2)
  }

  @Test func stopDuringStartupWaitsForOwnedStartupBeforeCleanup() async {
    let runtime = DesktopRuntimeFixture(blockStart: true)
    let controller = makeController(runtime)
    let start = Task { await controller.start() }
    await runtime.waitUntilStartRequested()
    let stop = Task { await controller.stop() }
    // Yield to the main actor so stop has entered its serialized transition.
    while controller.serviceState != .stopping { await Task.yield() }
    #expect(await runtime.stopCount == 0)
    await runtime.releaseStart()
    await start.value
    #expect(await stop.value)
    #expect(controller.serviceState == .stopped)
    #expect(await runtime.stopCount == 1)
  }

  @Test func startupFailureCleansUpAndAllowsRetry() async {
    let runtime = DesktopRuntimeFixture(failStart: true)
    let controller = makeController(runtime)
    await controller.start()
    #expect(controller.serviceState == .failed)
    #expect(controller.error != nil)
    #expect(controller.canStart)
    #expect(await runtime.stopCount == 1)
  }

  @Test func defaultProjectIsAppliedOnlyWhenHelperHasNoSavedProject() async {
    let runtime = DesktopRuntimeFixture(hasProject: false)
    let controller = makeController(runtime)
    await controller.start()
    #expect(await runtime.methods == ["status", "project/set", "start", "account/read"])
    #expect(await runtime.startParameters == [.object([:])])
    #expect(controller.projectName == "My Project")
    #expect(await controller.stop())
  }

  @Test func discoveryAndStatusDoNotReleasePairingSecret() async throws {
    let runtime = DesktopRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    await controller.refresh()
    #expect(await runtime.methods.contains("pairing/get") == false)
    let data = try await controller.pairingPayload()
    #expect(try JSONDecoder().decode(DesktopJSON.self, from: data)["v"] == .number(2))
    #expect(await runtime.methods.filter { $0 == "pairing/get" }.count == 1)
    #expect(await controller.stop())
  }

  @Test func accountEventChangesStateWithoutReturningCredentials() async {
    let runtime = DesktopRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    #expect(controller.accountState == .needsAttention)
    await runtime.emit(
      .message(
        name: "account",
        data: .object([
          "status": .string("authenticated"), "authMethod": .string("chatgpt"),
          "authToken": .string("synthetic-token-must-not-be-displayed"),
        ])))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while controller.accountState != .signedIn, ContinuousClock.now < deadline {
      await Task.yield()
    }
    #expect(controller.accountState == .signedIn)
    #expect(controller.nearbyReady)
    #expect(await runtime.methods == ["status", "start", "account/read"])
    #expect(await controller.stop())
    #expect(controller.accountState == .notChecked)
  }

  @Test func configuredProviderDoesNotClaimItsAuthenticationWasVerified() async {
    let runtime = DesktopRuntimeFixture(
      accountResponse: .object([
        "status": .string("authenticated"), "authMethod": .string("customProvider"),
      ]))
    let controller = makeController(runtime)
    await controller.start()
    #expect(controller.accountState == .configured)
    #expect(controller.nearbyReady)
    #expect(await runtime.startParameters == [.object([:])])
    #expect(await controller.stop())
  }

  @Test func unavailableAccountStatusDoesNotDisablePairing() async throws {
    let runtime = DesktopRuntimeFixture(failAccountRead: true)
    let controller = makeController(runtime)
    await controller.start()
    #expect(controller.accountState == .unavailable)
    #expect(controller.error == nil)
    #expect(controller.nearbyReady)
    let result = try await controller.pairingPayload()
    #expect(try JSONDecoder().decode(DesktopJSON.self, from: result)["v"] == .number(2))
    #expect(await controller.stop())
  }

  @Test func unexpectedExitRetainsCleanupGate() async {
    let runtime = DesktopRuntimeFixture()
    let controller = makeController(runtime)
    await controller.start()
    await runtime.emit(.exited(status: 1))
    while controller.serviceState != .cleanupUnconfirmed { await Task.yield() }
    #expect(controller.canStart == false)
    #expect(controller.canStop)
    #expect(await controller.stop())
  }

  private func makeController(_ runtime: DesktopRuntimeFixture) -> DesktopHostController {
    DesktopHostController(
      makeRuntime: { runtime },
      defaultProject: { URL(filePath: "/fixture/My Project", directoryHint: .isDirectory) })
  }
}

struct DesktopHostProtocolTests {
  @Test func helperInheritsCodexHomeButNotShellCredentialsOrOverrides() {
    let environment = DesktopPackagedRuntime.inheritedHelperEnvironment([
      "HOME": "/fixture", "CODEX_HOME": "/fixture/main-codex", "LANG": "en_US.UTF-8",
      "OPENAI_API_KEY": "synthetic-key", "CUSTOM_PROVIDER_TOKEN": "synthetic-token",
      "OPENAI_BASE_URL": "https://untrusted.invalid", "NODE_OPTIONS": "--fixture",
    ])
    #expect(
      environment == [
        "HOME": "/fixture", "CODEX_HOME": "/fixture/main-codex", "LANG": "en_US.UTF-8",
      ])
    #expect(DesktopPackagedRuntime.inheritedHelperEnvironment([:])["CODEX_HOME"] == nil)
  }

  @Test func ownershipMustMatchTheActualLocalHelper() {
    let trusted: DesktopJSON = .object([
      "ownership": .object(["ownerPid": .number(42), "groupId": .number(99)])
    ])
    #expect(DesktopProcessOwnership(status: trusted, expectedOwner: 42)?.groupId == 99)
    #expect(DesktopProcessOwnership(status: trusted, expectedOwner: 43) == nil)
    let invalid: DesktopJSON = .object([
      "ownership": .object(["ownerPid": .number(42), "groupId": .number(1)])
    ])
    #expect(DesktopProcessOwnership(status: invalid, expectedOwner: 42) == nil)
  }

  @Test func crashedHelperWithoutTrustedOwnershipRemainsPending() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "MunieDesktopCrashFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      do { try FileManager.default.removeItem(at: directory) } catch {
        Issue.record("Could not remove the owned crash fixture directory.")
      }
    }
    let script = directory.appending(path: "fixture.sh")
    // A response that spoofs another helper's ownership must never authorize crash recovery.
    try #"""
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
      printf '{"v":1,"id":"%s","result":{"state":"running","ownership":{"ownerPid":1,"groupId":999999}}}\n' "$request_id"
    done
    """#.write(to: script, atomically: true, encoding: .utf8)
    let runtime = DesktopPackagedRuntime(
      configuration: DesktopRuntimeConfiguration(
        node: URL(filePath: "/bin/sh"), entryPoint: script,
        codex: URL(filePath: "/usr/bin/true"), stateDirectory: directory,
        defaultProject: directory))
    _ = try await runtime.launch()
    _ = try await runtime.request("start")
    let helper = try #require(await runtime.helperProcessIdentifier())
    #expect(Darwin.kill(helper, SIGKILL) == 0)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await runtime.helperProcessIdentifier() != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await runtime.helperProcessIdentifier() == nil)
    await #expect(throws: DesktopHostFailure.cleanupUnconfirmed) { try await runtime.shutdown() }
  }

  @Test func idleDiagnosticPipeDoesNotBlockControlResponsesOrConfirmedShutdown() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "MunieDesktopPipeFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      do { try FileManager.default.removeItem(at: directory) } catch {
        Issue.record("Could not remove the owned pipe fixture directory.")
      }
    }
    let script = directory.appending(path: "fixture.sh")
    // This synthetic fixture intentionally leaves stderr idle; production never invokes a shell.
    try #"""
    printf '%s\n' '{"v":1,"event":"ready","data":{}}'
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
      printf '{"v":1,"id":"%s","result":{"state":"stopped","cleanupConfirmed":true}}\n' "$request_id"
    done
    """#.write(to: script, atomically: true, encoding: .utf8)
    let runtime = DesktopPackagedRuntime(
      configuration: DesktopRuntimeConfiguration(
        node: URL(filePath: "/bin/sh"), entryPoint: script,
        codex: URL(filePath: "/usr/bin/true"), stateDirectory: directory,
        defaultProject: directory))
    _ = try await runtime.launch()
    let result = try await runtime.request("status")
    #expect(result["state"]?.string == "stopped")
    try await runtime.shutdown()
    // A released runtime owns no child or open control handles, and shutdown is idempotent.
    try await runtime.shutdown()
  }

  @Test func frameLimitCountsBytesBeforeDecoding() throws {
    var buffer = DesktopHostLineBuffer()
    for _ in 0..<DesktopHostLineBuffer.maximumBytes {
      _ = try buffer.append(120)
    }
    #expect(throws: DesktopHostFailure.oversizedFrame) { try buffer.append(120) }
    #expect(try buffer.append(10)?.count == DesktopHostLineBuffer.maximumBytes)
    try buffer.finish()
  }

  @Test func incompleteAndEmptyFramesAreRejected() throws {
    var buffer = DesktopHostLineBuffer()
    #expect(throws: DesktopHostFailure.invalidProtocol) { try buffer.append(10) }
    _ = try buffer.append(123)
    #expect(throws: DesktopHostFailure.invalidProtocol) { try buffer.finish() }
  }

  @Test func invalidVersionAndAmbiguousResponsesAreRejected() {
    for text in [
      #"{"v":2,"id":"x","result":{}}"#,
      #"{"v":1,"id":"x","result":{},"error":{"code":"x"}}"#,
      #"{"v":1,"id":"x","result":{},"event":"status"}"#,
      #"{"v":1,"result":{}}"#,
    ] {
      #expect(throws: DesktopHostFailure.invalidProtocol) {
        try DesktopHostEnvelope.decode(Data(text.utf8))
      }
    }
  }

}

private actor DesktopRuntimeFixture: DesktopHostRuntime {
  private(set) var launchCount = 0
  private(set) var stopCount = 0
  private(set) var methods: [String] = []
  private(set) var startParameters: [DesktopJSON] = []
  private var stopFailures: Int
  private let failStart: Bool
  private let accountResponse: DesktopJSON
  private let failAccountRead: Bool
  private var blockStart: Bool
  private var hasProject: Bool
  private var isRunning = false
  private var startGate: CheckedContinuation<Void, Never>?
  private var startRequested = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var events: AsyncStream<DesktopHostEvent>.Continuation?

  init(
    stopFailures: Int = 0, failStart: Bool = false, blockStart: Bool = false,
    hasProject: Bool = true,
    accountResponse: DesktopJSON = .object(["status": .string("not_logged_in")]),
    failAccountRead: Bool = false
  ) {
    self.stopFailures = stopFailures
    self.failStart = failStart
    self.blockStart = blockStart
    self.hasProject = hasProject
    self.accountResponse = accountResponse
    self.failAccountRead = failAccountRead
  }

  func launch() -> AsyncStream<DesktopHostEvent> {
    launchCount += 1
    let (stream, continuation) = AsyncStream<DesktopHostEvent>.makeStream()
    events = continuation
    return stream
  }

  func request(_ method: String, params: DesktopJSON) async throws -> DesktopJSON {
    methods.append(method)
    if method == "project/set" { hasProject = true }
    if method == "start" {
      startParameters.append(params)
      startRequested = true
      for waiter in startWaiters { waiter.resume() }
      startWaiters.removeAll()
      if blockStart {
        await withCheckedContinuation { startGate = $0 }
      }
      if failStart { throw DesktopHostFailure.notRunning }
      isRunning = true
    }
    if method == "pairing/get" {
      return .object(["payload": .object(["v": .number(2)])])
    }
    if method == "account/read" {
      if failAccountRead { throw DesktopHostFailure.timedOut }
      return accountResponse
    }
    return .object([
      "state": .string(isRunning ? "running" : "stopped"),
      "lanAvailable": .bool(isRunning),
      "lanRevision": .number(isRunning ? 1 : 0),
      "project": hasProject
        ? .object(["path": .string("/fixture/My Project"), "name": .string("My Project")]) : .null,
      "account": .object(["status": .string("not_logged_in")]),
      "devices": .array([]),
    ])
  }

  func shutdown() throws {
    stopCount += 1
    if stopFailures > 0 {
      stopFailures -= 1
      throw DesktopHostFailure.cleanupUnconfirmed
    }
    events?.finish()
    isRunning = false
  }

  func waitUntilStartRequested() async {
    if startRequested { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func releaseStart() {
    blockStart = false
    startGate?.resume()
    startGate = nil
  }

  func emit(_ event: DesktopHostEvent) { events?.yield(event) }
}
