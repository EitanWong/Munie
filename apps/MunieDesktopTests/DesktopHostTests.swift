import Darwin
import Foundation
import Observation
import Testing

@testable import MunieDesktop

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
    #expect(controller.modelProvider == .chatGPT)
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
    #expect(controller.accountState == .signedOut)
    await runtime.emit(
      .message(name: "account", data: .object(["status": .string("authenticated")])))
    while controller.accountState != .signedIn { await Task.yield() }
    #expect(controller.loginURL == nil)
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

  @Test func savedAPIKeyOnlyEntersLocalStartParameters() async throws {
    let runtime = DesktopRuntimeFixture()
    let store = DesktopProviderStoreFixture()
    let controller = makeController(runtime, providerStore: store)
    let key = "synthetic-official-key"
    #expect(await controller.saveOpenAIAPIKey(key))
    #expect(await runtime.launchCount == 0)
    #expect(controller.modelProvider == .openAIAPIKey)
    await controller.start()
    #expect(await runtime.startParameters == [.object(["apiKey": .string(key)])])
    #expect(controller.modelProvider == .openAIAPIKey)
    #expect(controller.accountState == .unknown)
    #expect(controller.loginURL == nil)
    #expect(controller.nearbyReady)
    let pairing = try await controller.pairingPayload()
    #expect(!String(decoding: pairing, as: UTF8.self).contains(key))
    await controller.refresh()
    #expect(await controller.beginLogin() == nil)
    await controller.cancelLogin()
    #expect(
      await runtime.methods == ["status", "start", "pairing/get", "status"])
    #expect(await controller.stop())
    #expect(await controller.switchToChatGPT())
    #expect(controller.modelProvider == .chatGPT)
    #expect(await runtime.launchCount == 1)
    await controller.start()
    #expect(await runtime.startParameters.last == .object([:]))
    #expect(await controller.stop())
  }

  @Test func keyChangesRequireConfirmedStopAndKeepPriorSelectionOnFailure() async {
    let runtime = DesktopRuntimeFixture(stopFailures: 1)
    let store = DesktopProviderStoreFixture()
    let controller = makeController(runtime, providerStore: store)
    await controller.start()
    #expect(!controller.canChangeModelProvider)
    #expect(await controller.saveOpenAIAPIKey("synthetic-replacement") == false)
    #expect(await controller.switchToChatGPT() == false)
    #expect(await controller.stop() == false)
    #expect(!controller.canChangeModelProvider)
    #expect(await controller.saveOpenAIAPIKey("synthetic-replacement") == false)
    #expect(await controller.stop())
    #expect(await controller.saveOpenAIAPIKey("synthetic-original"))
    await store.failWrites()
    #expect(await controller.saveOpenAIAPIKey("synthetic-replacement") == false)
    #expect(await controller.switchToChatGPT() == false)
    #expect(controller.modelProvider == .openAIAPIKey)
    #expect(controller.modelProviderError == "Munie could not update the API key in the Keychain.")
    #expect(await store.savedKey() == "synthetic-original")
  }

  @Test func providerOperationAndStartupCannotOverlap() async {
    let runtime = DesktopRuntimeFixture()
    let store = DesktopProviderStoreFixture(blockSaves: true)
    let controller = makeController(runtime, providerStore: store)
    let save = Task { await controller.saveOpenAIAPIKey("synthetic-official-key") }
    await store.waitForOperation()
    #expect(controller.changingModelProvider)
    #expect(!controller.canStart)
    await controller.start()
    #expect(await runtime.launchCount == 0)
    #expect(await controller.stop() == false)
    #expect(await controller.switchToChatGPT() == false)
    await store.releaseOperation()
    #expect(await save.value)
    #expect(controller.canStart)
  }

  @Test func stoppingDuringKeyReadPreventsLateCredentialLaunch() async {
    let runtime = DesktopRuntimeFixture()
    let store = DesktopProviderStoreFixture(
      key: DesktopProviderKey(validating: "synthetic-official-key"), blockReads: true)
    let controller = makeController(runtime, providerStore: store)
    let start = Task { await controller.start() }
    await store.waitForOperation()
    #expect(!controller.canChangeModelProvider)
    let stop = Task { await controller.stop() }
    while controller.serviceState != .stopping { await Task.yield() }
    await store.releaseOperation()
    await start.value
    #expect(await stop.value)
    #expect(await runtime.launchCount == 0)
    #expect(await runtime.startParameters.isEmpty)
    #expect(controller.serviceState == .stopped)
  }

  @Test func unreadableKeychainDoesNotFallBackToChatGPT() async {
    let runtime = DesktopRuntimeFixture()
    let controller = makeController(
      runtime, providerStore: DesktopProviderStoreFixture(failReads: true))
    await controller.start()
    #expect(controller.serviceState == .failed)
    #expect(controller.modelProvider == .unknown)
    #expect(controller.modelProviderError == "Munie could not read the API key from the Keychain.")
    #expect(await runtime.launchCount == 0)
  }

  @Test func rejectedLocalKeyKeepsSelectionWithoutEchoingErrorPayload() async {
    let testKey = "synthetic-official-key"
    let runtime = DesktopRuntimeFixture(
      startError: DesktopHostControlError(code: "api_key_unavailable", message: testKey))
    let store = DesktopProviderStoreFixture(key: DesktopProviderKey(validating: testKey))
    let controller = makeController(runtime, providerStore: store)
    await controller.start()
    #expect(controller.serviceState == .failed)
    #expect(controller.modelProvider == .openAIAPIKey)
    #expect(
      controller.modelProviderError == "Munie could not load the official API key into Codex.")
    #expect(controller.error == nil)
    #expect(controller.canChangeModelProvider)
    #expect(await store.savedKey() == testKey)
  }

  @Test func customProviderStartsOnlyFromSavedConfigurationAndKeepsPairing() async throws {
    let runtime = DesktopRuntimeFixture()
    let store = DesktopProviderStoreFixture()
    let controller = makeController(runtime, providerStore: store)
    let key = "synthetic-custom-key"
    let baseURL = "https://provider.invalid:9443/v1/"
    let model = "vendor/model-1"
    #expect(await controller.saveCustomProvider(baseURL: baseURL, model: model, apiKey: key))
    #expect(await runtime.launchCount == 0)
    #expect(controller.modelProvider == .custom(baseURL: baseURL, model: model))
    await controller.start()
    let expected: DesktopJSON = .object([
      "customProvider": .object([
        "baseURL": .string(baseURL), "model": .string(model), "apiKey": .string(key),
      ])
    ])
    #expect(await runtime.startParameters == [expected])
    #expect(controller.nearbyReady)
    #expect(controller.accountState == .unknown)
    #expect(await controller.beginLogin() == nil)
    #expect(await controller.switchToChatGPT() == false)
    let pairing = try await controller.pairingPayload()
    #expect(!String(decoding: pairing, as: UTF8.self).contains(key))
    await controller.refresh()
    #expect(await runtime.methods == ["status", "start", "pairing/get", "status"])
    #expect(await controller.stop())
    #expect(await controller.switchToChatGPT())
    #expect(await runtime.launchCount == 1)
    await controller.start()
    #expect(await runtime.startParameters.last == .object([:]))
    #expect(await controller.stop())
  }

  @Test func invalidCustomSettingsPreserveAnExistingOfficialKey() async {
    let runtime = DesktopRuntimeFixture()
    let key = "synthetic-official-key"
    let store = DesktopProviderStoreFixture(key: DesktopProviderKey(validating: key))
    let controller = makeController(runtime, providerStore: store)
    await controller.start()
    #expect(await controller.stop())
    #expect(
      await controller.saveCustomProvider(
        baseURL: "https://provider.invalid/v1?bad=yes", model: "model", apiKey: "synthetic")
        == false)
    #expect(
      await controller.saveCustomProvider(
        baseURL: "https://provider.invalid/v1", model: "model name", apiKey: "synthetic") == false)
    #expect(
      await controller.saveCustomProvider(
        baseURL: "https://provider.invalid/v1", model: "model", apiKey: "key\n") == false)
    #expect(await store.savedKey() == key)
    #expect(controller.modelProvider == .openAIAPIKey)
  }

  @Test func invalidCustomRuntimeResponseDoesNotEchoPrivateSettings() async {
    let runtime = DesktopRuntimeFixture(
      startError: DesktopHostControlError(
        code: "custom_provider_unavailable", message: "synthetic-custom-key"))
    let controller = makeController(runtime)
    #expect(
      await controller.saveCustomProvider(
        baseURL: "https://provider.invalid/v1", model: "model", apiKey: "synthetic-custom-key"))
    await controller.start()
    #expect(controller.serviceState == .failed)
    #expect(controller.modelProviderError == "Munie could not configure the custom provider.")
    #expect(controller.error == nil)
  }

  private func makeController(
    _ runtime: DesktopRuntimeFixture,
    providerStore: any DesktopProviderStore = DesktopProviderStoreFixture()
  ) -> DesktopHostController {
    DesktopHostController(
      makeRuntime: { runtime },
      defaultProject: { URL(filePath: "/fixture/My Project", directoryHint: .isDirectory) },
      providerStore: providerStore)
  }
}

struct DesktopHostProtocolTests {
  @Test func providerRecordRoundTripsCustomAndPreservesUnambiguousLegacyOfficialKeys() throws {
    let key = try #require(DesktopProviderKey(validating: "synthetic-key"))
    #expect(try DesktopProviderRecord.decode(Data(key.value.utf8)) == .openAI(key))
    let profile = try #require(
      DesktopCustomProvider(baseURL: "https://provider.invalid/v1", model: "model", apiKey: key))
    let encoded = try DesktopProviderRecord.encode(.custom(profile))
    #expect(try DesktopProviderRecord.decode(encoded) == .custom(profile))
    #expect(throws: DesktopProviderStoreFailure.self) {
      try DesktopProviderRecord.decode(Data([0, 2, 0]))
    }
    #expect(throws: DesktopProviderStoreFailure.self) {
      try DesktopProviderRecord.decode(Data([0, 1, 0]))
    }
  }

  @Test func customProviderValidationRejectsAmbiguousURLsAndModels() {
    for value in [
      "http://provider.invalid/v1", "https:///v1", "https://name@provider.invalid/v1",
      "https://provider.invalid/v1?", "https://provider.invalid/v1#",
      "https://provider.invalid/a%2Fb",
      "https://provider.invalid/v1/../v2", "https://provider.invalid/v1//nested",
      "https://provider.invalid:99999/v1", "https://provider.invalid/v1;other",
      "https://provider.invalid/v1" + String(repeating: "x", count: 2048),
    ] {
      #expect(!DesktopCustomProvider.isValidBaseURL(value))
    }
    #expect(DesktopCustomProvider.isValidBaseURL("https://provider.invalid:9443/v1/"))
    #expect(
      DesktopCustomProvider.responsesEndpoint("https://provider.invalid:9443/v1/")
        == "https://provider.invalid:9443/v1/responses")
    #expect(DesktopCustomProvider.isValidModel("vendor/model-1:2.3_r"))
    for value in ["", "model name", "模型", "model?", String(repeating: "x", count: 129)] {
      #expect(!DesktopCustomProvider.isValidModel(value))
    }
  }

  @Test func keySyntaxMatchesTheBoundedLocalProtocol() {
    #expect(DesktopProviderKey(validating: String(repeating: "~", count: 512)) != nil)
    for value in ["", "key ", "key\n", "密钥", String(repeating: "x", count: 513)] {
      #expect(DesktopProviderKey(validating: value) == nil)
    }
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

  @Test func authURLRejectsRemoteAndScriptSchemes() throws {
    for value in [
      "http://auth.openai.com/login", "https://auth.openai.com.evil.example/login",
      "https://evil.example/login", "javascript:alert(1)", "file:///tmp/login",
      "https://user:password@auth.openai.com/login", "https://auth.openai.com:8443/login",
    ] {
      #expect(throws: DesktopHostFailure.loginURLRejected) { try DesktopLoginURL.validated(value) }
    }
    #expect(
      try DesktopLoginURL.validated("https://auth.openai.com/authorize?state=fixture").host
        == "auth.openai.com")
  }
}

private actor DesktopRuntimeFixture: DesktopHostRuntime {
  private(set) var launchCount = 0
  private(set) var stopCount = 0
  private(set) var methods: [String] = []
  private(set) var startParameters: [DesktopJSON] = []
  private var stopFailures: Int
  private let startError: (any Error)?
  private var blockStart: Bool
  private var hasProject: Bool
  private var isRunning = false
  private var startGate: CheckedContinuation<Void, Never>?
  private var startRequested = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var events: AsyncStream<DesktopHostEvent>.Continuation?

  init(
    stopFailures: Int = 0, failStart: Bool = false, blockStart: Bool = false,
    hasProject: Bool = true, startError: (any Error)? = nil
  ) {
    self.stopFailures = stopFailures
    self.startError = startError ?? (failStart ? DesktopHostFailure.notRunning : nil)
    self.blockStart = blockStart
    self.hasProject = hasProject
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
      if let startError { throw startError }
      isRunning = true
    }
    if method == "pairing/get" {
      return .object(["payload": .object(["v": .number(2)])])
    }
    if method == "account/read" { return .object(["status": .string("not_logged_in")]) }
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

actor DesktopProviderStoreFixture: DesktopProviderStore {
  private var credentials: DesktopProviderCredentials?
  private let blockReads: Bool
  private let blockSaves: Bool
  private let failReads: Bool
  private var failMutations = false
  private var operation: CheckedContinuation<Void, Never>?
  private var operationWaiter: CheckedContinuation<Void, Never>?

  init(
    key: DesktopProviderKey? = nil, blockReads: Bool = false,
    blockSaves: Bool = false, failReads: Bool = false
  ) {
    self.credentials = key.map { .openAI($0) }
    self.blockReads = blockReads
    self.blockSaves = blockSaves
    self.failReads = failReads
  }

  func read() async throws -> DesktopProviderCredentials? {
    if blockReads { await suspendOperation() }
    if failReads { throw DesktopProviderStoreFailure.unavailable }
    return credentials
  }

  func save(_ credentials: DesktopProviderCredentials) async throws {
    if blockSaves { await suspendOperation() }
    if failMutations { throw DesktopProviderStoreFailure.unavailable }
    self.credentials = credentials
  }

  func remove() throws {
    if failMutations { throw DesktopProviderStoreFailure.unavailable }
    credentials = nil
  }

  func savedKey() -> String? {
    guard case .openAI(let key) = credentials else { return nil }
    return key.value
  }

  func failWrites() { failMutations = true }

  func waitForOperation() async {
    if operation != nil { return }
    await withCheckedContinuation { operationWaiter = $0 }
  }

  func releaseOperation() {
    operation?.resume()
    operation = nil
  }

  private func suspendOperation() async {
    await withCheckedContinuation { continuation in
      operation = continuation
      operationWaiter?.resume()
      operationWaiter = nil
    }
  }
}
