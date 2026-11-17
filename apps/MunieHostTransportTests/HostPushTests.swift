import CryptoKit
import Darwin
import Foundation
import MunieRemote
import Testing

@testable import MunieHostTransport

struct HostPushTests {
  private let now = Date(timeIntervalSince1970: 1_794_985_200)
  private let deviceID = UUID()
  private let deviceToken = String(repeating: "ab", count: 32)

  @Test func providerJWTUsesNativeES256AndExactIssuerTimestamp() throws {
    let key = P256.Signing.PrivateKey()
    let configuration = try configuration(key: key)
    let jwt = try HostPushRequestBuilder.authorization(configuration, now: now)
    let segments = jwt.split(separator: ".")
    #expect(segments.count == 3)
    let header = try #require(
      try JSONSerialization.jsonObject(with: decode(segments[0])) as? [String: String])
    #expect(header == ["alg": "ES256", "kid": configuration.keyID])
    let payload = try #require(
      try JSONSerialization.jsonObject(with: decode(segments[1])) as? [String: Any])
    #expect(Set(payload.keys) == ["iss", "iat"])
    #expect(payload["iss"] as? String == configuration.teamID)
    #expect(payload["iat"] as? Int == Int(now.timeIntervalSince1970))
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(segments[2]))
    #expect(
      key.publicKey.isValidSignature(signature, for: Data("\(segments[0]).\(segments[1])".utf8)))
    #expect(!jwt.contains("="))
  }

  @Test(arguments: [RemotePhase.completed, .failed, .running])
  func payloadIncludesOnlyGenericStateAndFixedNavigation(phase: RemotePhase) throws {
    let approval =
      phase == .running
      ? RemoteApproval(
        id: UUID(), command: "PRIVATE-COMMAND", cwd: "/PRIVATE/PATH",
        reason: "PRIVATE-REASON", expiresAt: now.addingTimeInterval(42)) : nil
    let task = makeTask(phase: phase, approval: approval)
    let config = try configuration()
    let built = try #require(
      try HostPushRequestBuilder.request(
        config, deviceID: deviceID,
        deviceToken: deviceToken, task: task, authorization: "synthetic-jwt", now: now))
    #expect(built.request.url?.scheme == "https")
    #expect(built.request.url?.host == "api.sandbox.push.apple.com")
    #expect(built.request.url?.path == "/3/device/\(deviceToken)")
    #expect(built.request.value(forHTTPHeaderField: "authorization") == "bearer synthetic-jwt")
    #expect(built.request.value(forHTTPHeaderField: "apns-push-type") == "alert")
    let body = try #require(built.request.httpBody)
    #expect(body.count < 4096)
    let text = String(decoding: body, as: UTF8.self)
    #expect(!text.contains("PRIVATE"))
    let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(payload.keys) == ["aps", "munieTaskID", "munieEventID"])
    #expect(payload["munieTaskID"] as? String == task.id.uuidString)
    let event = approval.map { "approval:\($0.id)" } ?? phase.rawValue
    #expect(payload["munieEventID"] as? String == "\(task.requestID):\(event)")
    let collapse = try #require(built.request.value(forHTTPHeaderField: "apns-collapse-id"))
    #expect(collapse.utf8.count == 64)
    #expect(
      collapse
        == SHA256.hash(data: Data(built.identity.utf8)).map { String(format: "%02x", $0) }.joined())
    let expectedExpiration = Int(
      (approval?.expiresAt ?? now.addingTimeInterval(3600)).timeIntervalSince1970)
    #expect(
      built.request.value(forHTTPHeaderField: "apns-expiration") == String(expectedExpiration))
  }

  @Test func unsupportedAndExpiredEventsProduceNoRequest() throws {
    let config = try configuration()
    for phase in [RemotePhase.accepted, .running, .reconciling, .cancelled] {
      #expect(
        try HostPushRequestBuilder.request(
          config, deviceID: deviceID,
          deviceToken: deviceToken, task: makeTask(phase: phase), authorization: "unused", now: now)
          == nil)
    }
    let expired = RemoteApproval(id: UUID(), command: "private", cwd: "/private", expiresAt: now)
    #expect(
      try HostPushRequestBuilder.request(
        config, deviceID: deviceID,
        deviceToken: deviceToken, task: makeTask(phase: .running, approval: expired),
        authorization: "unused", now: now) == nil)
  }

  @Test func invalidConfigurationAndDeviceTokensAreRejected() throws {
    let key = P256.Signing.PrivateKey()
    #expect(throws: HostPushError.invalidConfiguration) {
      try HostPushConfiguration(
        teamID: "team\r\nBAD", keyID: "K1L2M3N4P5", topic: "app.munie.ios",
        privateKeyPEM: key.pemRepresentation, sandbox: true)
    }
    #expect(throws: HostPushError.invalidConfiguration) {
      try HostPushConfiguration(
        teamID: "A1B2C3D4E5", keyID: "invalid", topic: "app.munie.ios",
        privateKeyPEM: key.pemRepresentation, sandbox: true)
    }
    #expect(throws: HostPushError.invalidConfiguration) {
      try HostPushConfiguration(
        teamID: "A1B2C3D4E5", keyID: "K1L2M3N4P5", topic: "app..munie",
        privateKeyPEM: key.pemRepresentation, sandbox: true)
    }
    #expect(throws: HostPushError.invalidConfiguration) {
      try HostPushConfiguration(
        teamID: "A1B2C3D4E5", keyID: "K1L2M3N4P5", topic: "app.munie.ios",
        privateKeyPEM: "invalid-pem", sandbox: true)
    }
    let config = try configuration(key: key)
    for invalid in [
      String(repeating: "a", count: 65), "../credentials", String(repeating: "g", count: 64),
    ] {
      #expect(throws: HostPushError.invalidConfiguration) {
        try HostPushRequestBuilder.request(
          config, deviceID: deviceID, deviceToken: invalid,
          task: makeTask(phase: .completed), authorization: "unused", now: now)
      }
    }
  }

  @Test func credentialLoaderRequiresPrivateRegularOwnerFileAndValidP8() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "munie-push-\(UUID())")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer {
      do { try FileManager.default.removeItem(at: directory) } catch {
        Issue.record("Temporary synthetic push credentials could not be removed.")
      }
    }
    #expect(try HostPushNotifications.loadConfiguration(in: directory) == nil)
    let key = P256.Signing.PrivateKey()
    let data = try JSONSerialization.data(withJSONObject: [
      "teamID": "A1B2C3D4E5", "keyID": "K1L2M3N4P5",
      "topic": "app.munie.ios", "privateKeyPEM": key.pemRepresentation, "sandbox": true,
    ])
    let file = directory.appending(path: "APNs.json")
    try data.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(try HostPushNotifications.loadConfiguration(in: directory)?.topic == "app.munie.ios")
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    #expect(throws: HostPushError.insecureCredentialFile) {
      try HostPushNotifications.loadConfiguration(in: directory)
    }
    try FileManager.default.removeItem(at: file)
    #expect(mkfifo(file.path, 0o600) == 0)
    #expect(throws: HostPushError.insecureCredentialFile) {
      try HostPushNotifications.loadConfiguration(in: directory)
    }
    try FileManager.default.removeItem(at: file)
    try data.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let original = directory.appending(path: "private-original.json")
    try FileManager.default.moveItem(at: file, to: original)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
    #expect(throws: HostPushError.insecureCredentialFile) {
      try HostPushNotifications.loadConfiguration(in: directory)
    }
  }

  @Test func redirectsAreExplicitlyRejectedWithoutResumingAnyRequest() async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let origin = try #require(URL(string: "https://api.push.apple.com/3/device/synthetic"))
    let attacker = try #require(URL(string: "https://attacker.invalid/collect"))
    let response = try #require(
      HTTPURLResponse(
        url: origin, statusCode: 307, httpVersion: nil,
        headerFields: ["Location": attacker.absoluteString]))
    let task = session.dataTask(with: origin)  // Deliberately never resumed: no external requests.
    let delegate = HostPushSessionDelegate()
    let redirected: URLRequest? = await withCheckedContinuation { continuation in
      delegate.urlSession(
        session, task: task, willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: attacker)
      ) { continuation.resume(returning: $0) }
    }
    #expect(redirected == nil)
    #expect(task.state == .suspended)
    task.cancel()
  }

  @Test func responseBodyIsBoundedByDeclaredAndActualBytes() async throws {
    let url = try #require(URL(string: "https://api.push.apple.com/3/device/synthetic"))
    let large = try #require(
      HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Length": "8193"]))
    await #expect(throws: HostPushError.responseTooLarge) {
      try await HostPushResponse.consume(bytes(0), response: large, expectedURL: url)
    }
    let unknown = try #require(
      HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: [:]))
    #expect(
      try await HostPushResponse.consume(bytes(8192), response: unknown, expectedURL: url) == 400)
    await #expect(throws: HostPushError.responseTooLarge) {
      try await HostPushResponse.consume(bytes(8193), response: unknown, expectedURL: url)
    }
    let other = try #require(URL(string: "https://another.invalid/"))
    await #expect(throws: HostPushError.invalidResponse) {
      try await HostPushResponse.consume(bytes(0), response: unknown, expectedURL: other)
    }
  }

  @Test func cancelledResponseCannotBeAcceptedAndDisabledSenderMakesNoRequests() async throws {
    let url = try #require(URL(string: "https://api.push.apple.com/3/device/synthetic"))
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]))
    let stream = AsyncStream<UInt8> { _ in }
    let operation = Task {
      try await HostPushResponse.consume(stream, response: response, expectedURL: url)
    }
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    let disabled = HostPushNotifications(configuration: nil)
    #expect(!disabled.isEnabled)
    await disabled.send(deviceID: UUID(), task: makeTask(phase: .completed))
    #expect(await disabled.lastStatus == nil)
    await disabled.close()
    await disabled.send(deviceID: UUID(), task: makeTask(phase: .completed))
    #expect(await disabled.lastStatus == nil)
  }

  @Test func exactEventIdentitySeparatesContinuationAndKeepsInterleavedAcceptances() throws {
    let config = try configuration()
    let task = makeTask(phase: .completed)
    let first = try #require(
      try HostPushRequestBuilder.request(
        config, deviceID: deviceID,
        deviceToken: deviceToken, task: task, authorization: "unused", now: now))
    let repeated = try #require(
      try HostPushRequestBuilder.request(
        config, deviceID: deviceID,
        deviceToken: deviceToken, task: task, authorization: "unused", now: now))
    #expect(first.identity == repeated.identity)
    #expect(
      first.request.value(forHTTPHeaderField: "apns-collapse-id")
        == repeated.request.value(forHTTPHeaderField: "apns-collapse-id"))
    let continuation = RemoteTask(
      id: task.id, requestID: UUID(), projectID: task.projectID,
      title: task.title, phase: .completed)
    let next = try #require(
      try HostPushRequestBuilder.request(
        config, deviceID: deviceID,
        deviceToken: deviceToken, task: continuation, authorization: "unused", now: now))
    #expect(next.identity != first.identity)
    var accepted = HostPushAcceptedEvents()
    accepted.record(first.identity)
    accepted.record(next.identity)
    accepted.record(first.identity)
    #expect(accepted.contains(first.identity))
    #expect(accepted.contains(next.identity))
    for index in 0..<1_000 { accepted.record("later-\(index)") }
    #expect(!accepted.contains(first.identity))
    #expect(accepted.contains("later-999"))
  }

  private func configuration(key: P256.Signing.PrivateKey = .init()) throws -> HostPushConfiguration
  {
    try HostPushConfiguration(
      teamID: "A1B2C3D4E5", keyID: "K1L2M3N4P5", topic: "app.munie.ios",
      privateKeyPEM: key.pemRepresentation, sandbox: true)
  }

  private func makeTask(phase: RemotePhase, approval: RemoteApproval? = nil) -> RemoteTask {
    RemoteTask(
      id: UUID(), requestID: UUID(), projectID: UUID(), title: "PRIVATE-TITLE", phase: phase,
      approval: approval,
      messages: [
        RemoteMessage(role: .user, text: "PRIVATE-PROMPT"),
        RemoteMessage(role: .assistant, text: "PRIVATE-RESULT"),
      ], updatedAt: now)
  }

  private func decode(_ segment: Substring) throws -> Data {
    var text = String(segment).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    text += String(repeating: "=", count: (4 - text.count % 4) % 4)
    return try #require(Data(base64Encoded: text))
  }

  private func bytes(_ count: Int) -> AsyncStream<UInt8> {
    AsyncStream { continuation in
      for _ in 0..<count { continuation.yield(0) }
      continuation.finish()
    }
  }
}
