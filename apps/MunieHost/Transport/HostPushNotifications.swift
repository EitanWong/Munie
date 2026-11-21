import CryptoKit
import Darwin
import Foundation
import MunieProductHost
import MunieRemote

public enum HostPushError: Error, Equatable {
  case invalidConfiguration, insecureCredentialFile, responseTooLarge, invalidResponse
}

/// Supplied locally by the owner, outside the repository and native workspace.
public struct HostPushConfiguration: Decodable, Sendable {
  public let teamID: String
  public let keyID: String
  public let topic: String
  public let privateKeyPEM: String
  public let sandbox: Bool

  public init(teamID: String, keyID: String, topic: String, privateKeyPEM: String, sandbox: Bool)
    throws
  {
    let validID: (String) -> Bool = { value in
      value.utf8.count == 10
        && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
    }
    let components = topic.split(separator: ".", omittingEmptySubsequences: false)
    guard validID(teamID), validID(keyID), (3...255).contains(topic.utf8.count),
      components.count >= 2, components.allSatisfy({ !$0.isEmpty }),
      topic.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 46
      }), !privateKeyPEM.isEmpty, privateKeyPEM.utf8.count <= 16_384
    else { throw HostPushError.invalidConfiguration }
    do { _ = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM) } catch {
      throw HostPushError.invalidConfiguration
    }
    self.teamID = teamID
    self.keyID = keyID
    self.topic = topic
    self.privateKeyPEM = privateKeyPEM
    self.sandbox = sandbox
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      teamID: values.decode(String.self, forKey: .teamID),
      keyID: values.decode(String.self, forKey: .keyID),
      topic: values.decode(String.self, forKey: .topic),
      privateKeyPEM: values.decode(String.self, forKey: .privateKeyPEM),
      sandbox: values.decode(Bool.self, forKey: .sandbox))
  }
  private enum CodingKeys: String, CodingKey { case teamID, keyID, topic, privateKeyPEM, sandbox }
}

public actor HostPushNotifications {
  public nonisolated static func loadConfiguration(in directory: URL) throws
    -> HostPushConfiguration?
  {
    guard directory.isFileURL else { throw HostPushError.insecureCredentialFile }
    let descriptor = open(
      directory.appending(path: "APNs.json").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw HostPushError.insecureCredentialFile
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(), before.st_mode & 0o077 == 0, before.st_nlink == 1,
      before.st_size > 0, before.st_size <= 65_536
    else { throw HostPushError.insecureCredentialFile }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw HostPushError.insecureCredentialFile
      }
      if count == 0 { break }
      guard data.count + count <= 65_536 else { throw HostPushError.insecureCredentialFile }
      data.append(contentsOf: buffer.prefix(count))
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, data.count == before.st_size,
      after.st_size == before.st_size, after.st_uid == before.st_uid,
      after.st_mode == before.st_mode, after.st_nlink == 1,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
    else { throw HostPushError.insecureCredentialFile }
    do { return try JSONDecoder().decode(HostPushConfiguration.self, from: data) } catch {
      throw HostPushError.invalidConfiguration
    }
  }

  public nonisolated let isEnabled: Bool
  private let configuration: HostPushConfiguration?
  private let session: URLSession
  private weak var host: ProductHost?
  private var cachedToken: (String, Date)?
  private var acceptedEvents = HostPushAcceptedEvents()
  private var inFlight: Set<String> = []
  private var closed = false
  public private(set) var lastStatus: Int?

  public init(configuration: HostPushConfiguration?) {
    self.configuration = configuration
    isEnabled = configuration != nil
    let native = URLSessionConfiguration.ephemeral
    native.timeoutIntervalForRequest = 5
    native.timeoutIntervalForResource = 10
    native.requestCachePolicy = .reloadIgnoringLocalCacheData
    native.urlCache = nil
    native.httpCookieStorage = nil
    native.httpShouldSetCookies = false
    native.urlCredentialStorage = nil
    native.connectionProxyDictionary = [:]
    native.httpMaximumConnectionsPerHost = 1
    session = URLSession(
      configuration: native, delegate: HostPushSessionDelegate(), delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }
  public func bind(_ host: ProductHost) { self.host = host }

  /// Explicit shutdown cancels a response body still being consumed.
  public func close() {
    closed = true
    host = nil
    session.invalidateAndCancel()
  }

  public func send(deviceID: UUID, task: RemoteTask) async {
    guard !closed, !Task.isCancelled, let configuration, let host,
      let deviceToken = await host.notificationToken(deviceID: deviceID), !closed, !Task.isCancelled
    else { return }
    do {
      let now = Date()
      let token: String
      if let cachedToken, (0..<3000).contains(now.timeIntervalSince(cachedToken.1)) {
        token = cachedToken.0
      } else {
        token = try HostPushRequestBuilder.authorization(configuration, now: now)
        cachedToken = (token, now)
      }
      guard
        let built = try HostPushRequestBuilder.request(
          configuration, deviceID: deviceID,
          deviceToken: deviceToken, task: task, authorization: token, now: now),
        let url = built.request.url,
        !acceptedEvents.contains(built.identity), !inFlight.contains(built.identity)
      else { return }
      inFlight.insert(built.identity)
      defer { inFlight.remove(built.identity) }
      let (bytes, response) = try await session.bytes(for: built.request)
      defer { bytes.task.cancel() }
      let status = try await HostPushResponse.consume(bytes, response: response, expectedURL: url)
      try Task.checkCancellation()
      guard !closed else { return }
      lastStatus = status
      if status == 200 {
        // HTTP 200 establishes APNs acceptance, not delivery or user presentation.
        acceptedEvents.record(built.identity)
      }
    } catch { lastStatus = nil }
  }
}

enum HostPushRequestBuilder {
  static func authorization(_ configuration: HostPushConfiguration, now: Date) throws -> String {
    let header = try JSONSerialization.data(withJSONObject: [
      "alg": "ES256", "kid": configuration.keyID,
    ])
    let payload = try JSONSerialization.data(withJSONObject: [
      "iss": configuration.teamID,
      "iat": Int(now.timeIntervalSince1970),
    ])
    let signingInput = "\(base64URL(header)).\(base64URL(payload))"
    let key = try P256.Signing.PrivateKey(pemRepresentation: configuration.privateKeyPEM)
    let signature = try key.signature(for: Data(signingInput.utf8))
    return "\(signingInput).\(base64URL(signature.rawRepresentation))"
  }

  static func request(
    _ configuration: HostPushConfiguration, deviceID: UUID, deviceToken: String,
    task: RemoteTask, authorization: String, now: Date
  ) throws -> (request: URLRequest, identity: String)? {
    guard (64...512).contains(deviceToken.utf8.count), deviceToken.utf8.count.isMultiple(of: 2),
      deviceToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw HostPushError.invalidConfiguration }
    let event: String
    let key: String
    var expiration = now.addingTimeInterval(3600)
    if let approval = task.approval {
      guard approval.expiresAt > now else { return nil }
      event = "approval:\(approval.id)"
      key = "A task needs your approval."
      expiration = min(expiration, approval.expiresAt)
    } else if task.phase == .completed || task.phase == .failed {
      event = task.phase.rawValue
      key =
        task.phase == .completed
        ? "Your task is complete." : "A task failed. Open Munie to review it."
    } else {
      return nil
    }
    let identity = "\(deviceID):\(task.id):\(task.requestID):\(event)"
    let server = configuration.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
    guard let url = URL(string: "https://\(server)/3/device/\(deviceToken)") else {
      throw HostPushError.invalidConfiguration
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("bearer \(authorization)", forHTTPHeaderField: "authorization")
    request.setValue(configuration.topic, forHTTPHeaderField: "apns-topic")
    request.setValue("alert", forHTTPHeaderField: "apns-push-type")
    request.setValue("10", forHTTPHeaderField: "apns-priority")
    request.setValue(
      String(Int(expiration.timeIntervalSince1970)), forHTTPHeaderField: "apns-expiration")
    request.setValue(
      SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined(),
      forHTTPHeaderField: "apns-collapse-id")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "aps": [
        "alert": ["title-loc-key": "Munie task update", "loc-key": key],
        "sound": "default", "thread-id": task.id.uuidString,
      ],
      "munieTaskID": task.id.uuidString, "munieEventID": "\(task.requestID):\(event)",
    ])
    return (request, identity)
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}

/// Exact acceptance history stays bounded and survives interleaved task notifications in this process.
struct HostPushAcceptedEvents {
  private var events: Set<String> = []
  private var order: [String] = []
  func contains(_ identity: String) -> Bool { events.contains(identity) }
  mutating func record(_ identity: String) {
    guard events.insert(identity).inserted else { return }
    order.append(identity)
    if order.count > 1_000 { events.remove(order.removeFirst()) }
  }
}

enum HostPushResponse {
  static let maximumBytes = 8192
  static func consume<Bytes: AsyncSequence>(_ bytes: Bytes, response: URLResponse, expectedURL: URL)
    async throws -> Int where Bytes.Element == UInt8
  {
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse, response.url == expectedURL else {
      throw HostPushError.invalidResponse
    }
    guard response.expectedContentLength <= Int64(maximumBytes) else {
      throw HostPushError.responseTooLarge
    }
    var count = 0
    for try await _ in bytes {
      try Task.checkCancellation()
      guard count < maximumBytes else { throw HostPushError.responseTooLarge }
      count += 1
    }
    try Task.checkCancellation()
    return response.statusCode
  }
}

final class HostPushSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // Never forward the provider JWT to a redirected request, including another Apple URL.
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}
