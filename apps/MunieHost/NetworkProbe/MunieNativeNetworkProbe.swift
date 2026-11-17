import Foundation
import MunieExecutionHost
import Security
import Synchronization

struct FixtureConfiguration: Decodable {
  let port: Int
  let caDERPath: String
  let identityPKCS12Path: String?
  let passphrase: String?

  func validate() throws {
    guard (1024...65535).contains(port), caDERPath.hasPrefix("/"),
      identityPKCS12Path.map({ $0.hasPrefix("/") }) ?? true,
      (identityPKCS12Path == nil) == (passphrase == nil)
    else { throw ProbeFailure.invalidConfiguration }
  }

  func endpoint(path: String) throws -> URL {
    try validate()
    guard ["submit", "snapshot", "redirect", "oversized", "slow"].contains(path),
      let url = URL(string: "https://127.0.0.1:\(port)/fixture/\(path)")
    else { throw ProbeFailure.invalidRequest }
    return url
  }
}

enum ProbeFailure: Error {
  case invalidConfiguration, invalidRequest, identityImport, certificate, inputLimit,
    invalidResponse
}

struct FixtureCommand: Decodable {
  let path: String
  let requestID: String
  let projectID: String
  let payload: String
  let cancel: Bool
}

struct TransferResult: Sendable {
  var status: Int?
  var body = Data()
  var errorCode: Int?
  var overflow = false
  var redirectRejected = false
  var cancelledOnResponse = false
  var serverChallenges = 0
  var clientChallenges = 0
  var trustRejected = 0
  var tlsProtocol: UInt16?
  var proxy: Bool?
}

private struct TransferState {
  var result = TransferResult()
  var continuation: CheckedContinuation<TransferResult, Never>?
  var invalidation: CheckedContinuation<Void, Never>?
  var cancelOnResponse = false
}

final class FixtureSessionDelegate: NSObject, URLSessionDataDelegate {
  let port: Int
  let anchor: SecCertificate
  private let identity: Mutex<SecIdentity?>
  private let state = Mutex(TransferState())
  static let responseLimit = 2048

  init(port: Int, anchor: SecCertificate, identity: sending SecIdentity?) {
    self.port = port
    self.anchor = anchor
    self.identity = Mutex(identity)
  }

  var hasIdentity: Bool { identity.withLock { $0 != nil } }

  func begin(
    _ continuation: CheckedContinuation<TransferResult, Never>, cancelOnResponse: Bool = false
  ) {
    state.withLock {
      $0.result = TransferResult()
      $0.continuation = continuation
      $0.cancelOnResponse = cancelOnResponse
    }
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let space = challenge.protectionSpace
    guard space.host == "127.0.0.1", space.port == port, !space.isProxy(),
      space.protocol == "https", challenge.previousFailureCount == 0
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    switch space.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
      state.withLock { $0.result.serverChallenges += 1 }
      guard let trust = space.serverTrust, validateFixtureServerTrust(trust, anchor: anchor)
      else {
        state.withLock { $0.result.trustRejected += 1 }
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(trust: trust))
    case NSURLAuthenticationMethodClientCertificate:
      state.withLock { $0.result.clientChallenges += 1 }
      // Apple ignores this credential's persistence argument. The identity itself was
      // imported with kSecImportToMemoryOnly; the session has no credential storage.
      identity.withLock { identity in
        guard let identity else {
          completionHandler(.cancelAuthenticationChallenge, nil)
          return
        }
        completionHandler(
          .useCredential,
          URLCredential(identity: identity, certificates: nil, persistence: .forSession))
      }
    default:
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    state.withLock { $0.result.redirectRejected = true }
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      return
    }
    state.withLock { $0.result.status = http.statusCode }
    if state.withLock({ $0.cancelOnResponse }) {
      state.withLock { $0.result.cancelledOnResponse = true }
      completionHandler(.cancel)
      return
    }
    if response.expectedContentLength > Self.responseLimit {
      state.withLock { $0.result.overflow = true }
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let overflow = state.withLock {
      if $0.result.overflow || $0.result.cancelledOnResponse { return true }
      if data.count > Self.responseLimit - $0.result.body.count {
        $0.result.overflow = true
        return true
      }
      $0.result.body.append(data)
      return false
    }
    if overflow { dataTask.cancel() }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    state.withLock { value in
      if let transaction = metrics.transactionMetrics.last {
        value.result.tlsProtocol = transaction.negotiatedTLSProtocolVersion?.rawValue
        value.result.proxy = transaction.isProxyConnection
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let pair = state.withLock {
      if let error {
        $0.result.errorCode = (error as? URLError)?.errorCode ?? -1
      }
      let pair = ($0.continuation, $0.result)
      $0.continuation = nil
      return pair
    }
    pair.0?.resume(returning: pair.1)
  }

  func prepareInvalidation(_ continuation: CheckedContinuation<Void, Never>) {
    state.withLock { $0.invalidation = continuation }
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    let continuation = state.withLock {
      let continuation = $0.invalidation
      $0.invalidation = nil
      return continuation
    }
    continuation?.resume()
  }
}

func validateFixtureServerTrust(_ trust: SecTrust, anchor: SecCertificate) -> Bool {
  SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "127.0.0.1" as CFString)) == errSecSuccess
    && SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess
    && SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
    && SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
    && SecTrustEvaluateWithError(trust, nil)
}

func readFixtureFile(_ path: String, limit: Int) throws -> Data {
  let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
  let data: Data
  do {
    data = try file.read(upToCount: limit + 1) ?? Data()
  } catch {
    try file.close()
    throw error
  }
  try file.close()
  guard data.count <= limit else { throw ProbeFailure.inputLimit }
  return data
}

func importFixtureIdentity(_ configuration: FixtureConfiguration) throws -> SecIdentity? {
  guard let path = configuration.identityPKCS12Path, let passphrase = configuration.passphrase
  else {
    return nil
  }
  let data = try readFixtureFile(path, limit: 16_384)
  let options: [CFString: Any] = [
    kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true,
  ]
  var items: CFArray?
  guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
    let imported = items as? [[CFString: Any]], imported.count == 1,
    let value = imported.first?[kSecImportItemIdentity],
    CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
  else { throw ProbeFailure.identityImport }
  return (value as! SecIdentity)
}

func fixtureSession(delegate: FixtureSessionDelegate) -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.urlCache = nil
  configuration.httpCookieStorage = nil
  configuration.httpShouldSetCookies = false
  configuration.urlCredentialStorage = nil
  configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
  configuration.waitsForConnectivity = false
  configuration.timeoutIntervalForRequest = 3
  configuration.timeoutIntervalForResource = 5
  configuration.httpMaximumConnectionsPerHost = 1
  configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
  configuration.tlsMaximumSupportedProtocolVersion = .TLSv13
  configuration.connectionProxyDictionary = [
    "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
    "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
  ]
  let queue = OperationQueue()
  queue.maxConcurrentOperationCount = 1
  return URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
}

func readFixtureLine() throws -> Data? {
  var bytes = Data()
  while let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty {
    if byte.first == 10 { return bytes }
    guard bytes.count < 4096 else { throw ProbeFailure.inputLimit }
    bytes.append(byte)
  }
  guard bytes.isEmpty else { throw ProbeFailure.invalidRequest }
  return nil
}

func emit(_ value: [String: Any]) throws {
  var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  guard data.count < 4096 else { throw ProbeFailure.invalidResponse }
  data.append(10)
  try FileHandle.standardOutput.write(contentsOf: data)
}

func invalidateFixtureSession(_ session: URLSession, delegate: FixtureSessionDelegate) async {
  await withCheckedContinuation { continuation in
    delegate.prepareInvalidation(continuation)
    session.invalidateAndCancel()
  }
}

func parseFixtureReply(_ data: Data) throws -> [String: Any] {
  guard data.count <= FixtureSessionDelegate.responseLimit,
    let object = try CodexJSON.decode(data).object
  else { throw ProbeFailure.invalidResponse }
  if Set(object.keys) == ["state", "ordinal"], object["state"]?.string == "fixture-accepted",
    let ordinal = object["ordinal"]?.integer, (1...4).contains(ordinal)
  {
    return ["state": "fixture-accepted", "ordinal": Int(ordinal)]
  }
  if Set(object.keys) == ["error"], let error = object["error"]?.string,
    [
      "device-denied", "project-denied", "request-conflict", "fixture-capacity", "unauthorized",
      "invalid-request", "unknown-request",
    ].contains(error)
  {
    return ["fixtureError": error]
  }
  if Set(object.keys) == ["state", "requestID", "phase"],
    object["state"]?.string == "ledger-snapshot", let requestID = object["requestID"]?.string,
    let id = UUID(uuidString: requestID), id.uuidString == requestID,
    let phase = object["phase"]?.string, SubmissionPhase(rawValue: phase) != nil
  {
    // Separate real ledger evidence from the original in-memory fixture's ordinal.
    return ["state": "ledger-snapshot", "requestID": requestID, "phase": phase]
  }
  throw ProbeFailure.invalidResponse
}

@main
struct MunieNativeNetworkProbe {
  static func main() async {
    do {
      guard CommandLine.arguments.count == 2 else { throw ProbeFailure.invalidConfiguration }
      let data = try readFixtureFile(CommandLine.arguments[1], limit: 4096)
      let configuration = try JSONDecoder().decode(FixtureConfiguration.self, from: data)
      try configuration.validate()
      let certificateData = try readFixtureFile(configuration.caDERPath, limit: 8192)
      guard let anchor = SecCertificateCreateWithData(nil, certificateData as CFData)
      else { throw ProbeFailure.certificate }
      let delegate = FixtureSessionDelegate(
        port: configuration.port, anchor: anchor, identity: try importFixtureIdentity(configuration)
      )
      let session = fixtureSession(delegate: delegate)
      do {
        try emit(["event": "ready", "memoryOnlyIdentity": delegate.hasIdentity])
        while let line = try readFixtureLine() {
          let command = try JSONDecoder().decode(FixtureCommand.self, from: line)
          let endpoint = try configuration.endpoint(path: command.path)
          var request = URLRequest(url: endpoint)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          if command.cancel {
            request.setValue("after-response", forHTTPHeaderField: "X-Munie-Fixture-Cancel")
          }
          let body: [String: String] =
            command.path == "snapshot"
            ? ["requestID": command.requestID]
            : [
              "requestID": command.requestID, "projectID": command.projectID,
              "payload": command.payload,
            ]
          request.httpBody = try JSONSerialization.data(withJSONObject: body)
          guard let requestBody = request.httpBody, requestBody.count <= 2048 else {
            throw ProbeFailure.inputLimit
          }
          let result = await withCheckedContinuation { continuation in
            delegate.begin(continuation, cancelOnResponse: command.cancel)
            let task = session.dataTask(with: request)
            task.resume()
          }
          var output: [String: Any] = [
            "event": "result", "bodyBytes": result.body.count, "overflow": result.overflow,
            "redirectRejected": result.redirectRejected,
            "cancelledOnResponse": result.cancelledOnResponse,
            "serverChallenges": result.serverChallenges,
            "clientChallenges": result.clientChallenges, "trustRejected": result.trustRejected,
          ]
          output["httpStatus"] = result.status
          output["errorCode"] = result.errorCode
          output["tlsProtocol"] = result.tlsProtocol
          output["proxy"] = result.proxy
          if result.errorCode == nil, !result.overflow, !result.redirectRejected {
            // Reuse the existing strict parser: JSON booleans/floats cannot become Ints,
            // and duplicate or unknown fields cannot disappear during sanitization.
            output.merge(try parseFixtureReply(result.body)) { _, new in new }
          }
          try emit(output)
        }
      } catch {
        await invalidateFixtureSession(session, delegate: delegate)
        throw error
      }
      await invalidateFixtureSession(session, delegate: delegate)
      try emit(["event": "closed", "sessionInvalidated": true])
    } catch {
      // Deliberately omit errors, file paths, payloads, passwords and certificate data.
      try? FileHandle.standardError.write(contentsOf: Data("Native network probe failed\n".utf8))
      exit(1)
    }
  }
}
