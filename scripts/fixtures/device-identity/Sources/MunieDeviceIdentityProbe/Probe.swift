import Crypto
import Foundation
import Security
import Synchronization

enum ProbeError: Error { case rejected(String) }

func require(_ condition: Bool, _ stage: String) throws {
  if !condition { throw ProbeError.rejected(stage) }
}

func emit(_ fields: [String: Any]) throws {
  var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
  data.append(10)
  try FileHandle.standardOutput.write(contentsOf: data)
}

func digest(_ bytes: Data) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

func fixtureFile(_ root: URL, _ name: String) throws -> Data {
  try require(!name.isEmpty && !name.contains("/") && !name.contains(".."), "filename")
  let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(name))
  defer { try? handle.close() }
  let data = try handle.read(upToCount: 16_385) ?? Data()
  try require(!data.isEmpty && data.count <= 16_384, "file-size")
  return data
}

func certificate(_ root: URL, _ name: String) throws -> SecCertificate {
  guard let value = SecCertificateCreateWithData(nil, try fixtureFile(root, name) as CFData)
  else { throw ProbeError.rejected("certificate") }
  return value
}

func localKey() throws -> SecKey {
  let attributes: [CFString: Any] = [
    kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
    kSecAttrKeySizeInBits: 256,
    kSecAttrIsPermanent: false,
    kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false],
  ]
  var error: Unmanaged<CFError>?
  guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error)
  else { throw ProbeError.rejected("memory-key-generation") }
  guard let properties = SecKeyCopyAttributes(key) as? [CFString: Any],
    properties[kSecAttrKeySizeInBits] as? Int == 256,
    (properties[kSecAttrIsPermanent] as? Bool) != true
  else { throw ProbeError.rejected("memory-key-attributes") }
  return key
}

func publicBytes(_ key: SecKey) throws -> Data {
  guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
    attributes[kSecAttrKeyClass] as? String == kSecAttrKeyClassPublic as String
  else { throw ProbeError.rejected("refuse-private-key-export") }
  var error: Unmanaged<CFError>?
  guard let value = SecKeyCopyExternalRepresentation(key, &error)
  else { throw ProbeError.rejected("public-key-encoding") }
  return value as Data
}

struct ProbeCase: Decodable {
  let name: String
  let certificate: String?
  let port: Int?
  let anchor: String
}

struct Configuration: Decodable {
  let port: Int
  let anchor: String
  let cases: [ProbeCase]
}

struct Outcome: Sendable {
  var status: Int?
  var errorCode: Int?
  var body = Data()
  var serverChallenges = 0
  var clientChallenges = 0
  var trustRejected = 0
  var tlsProtocol: UInt16?
  var proxy: Bool?
  var overflow = false
  var redirect = false
}

struct SessionState {
  var result = Outcome()
  var completion: CheckedContinuation<Outcome, Never>?
}

struct CredentialState {
  let key: SecKey
  var identity: SecIdentity?
}

final class Credentials: Sendable {
  let state: Mutex<CredentialState>
  init(key: sending SecKey) { state = Mutex(CredentialState(key: key)) }
  func install(_ der: Data?) throws {
    try state.withLock {
      guard let der else {
        $0.identity = nil
        return
      }
      guard let leaf = SecCertificateCreateWithData(nil, der as CFData),
        let identity = SecIdentityCreate(nil, leaf, $0.key)
      else { throw ProbeError.rejected("case-identity-create") }
      $0.identity = identity
    }
  }
}

final class ProbeDelegate: NSObject, URLSessionDataDelegate {
  let port: Int
  let anchor: SecCertificate
  let credentials: Credentials
  let state = Mutex(SessionState())
  let invalidation = SessionInvalidation()
  init(port: Int, anchor: SecCertificate, credentials: Credentials) {
    self.port = port
    self.anchor = anchor
    self.credentials = credentials
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let space = challenge.protectionSpace
    guard space.host == "127.0.0.1", space.port == port, space.protocol == "https",
      !space.isProxy(), challenge.previousFailureCount == 0
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    switch space.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
      state.withLock { $0.result.serverChallenges += 1 }
      guard let trust = space.serverTrust,
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "127.0.0.1" as CFString)) == 0,
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == 0,
        SecTrustSetAnchorCertificatesOnly(trust, true) == 0,
        SecTrustSetNetworkFetchAllowed(trust, false) == 0,
        SecTrustEvaluateWithError(trust, nil)
      else {
        state.withLock { $0.result.trustRejected += 1 }
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(trust: trust))
    case NSURLAuthenticationMethodClientCertificate:
      state.withLock { $0.result.clientChallenges += 1 }
      credentials.state.withLock {
        guard let identity = $0.identity else {
          completionHandler(.cancelAuthenticationChallenge, nil)
          return
        }
        completionHandler(
          .useCredential,
          URLCredential(
            identity: identity, certificates: nil, persistence: .forSession))
      }
    default: completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    state.withLock { $0.result.redirect = true }
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse, response.expectedContentLength <= 2048
    else {
      completionHandler(.cancel)
      return
    }
    state.withLock { $0.result.status = http.statusCode }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let cancel = state.withLock {
      guard !$0.result.overflow, data.count <= 2048 - $0.result.body.count else {
        $0.result.overflow = true
        return true
      }
      $0.result.body.append(data)
      return false
    }
    if cancel { dataTask.cancel() }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    state.withLock {
      $0.result.tlsProtocol =
        metrics.transactionMetrics.last?.negotiatedTLSProtocolVersion?.rawValue
      $0.result.proxy = metrics.transactionMetrics.last?.isProxyConnection
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let pair = state.withLock {
      if let error { $0.result.errorCode = (error as NSError).code }
      let pair = ($0.completion, $0.result)
      $0.completion = nil
      return pair
    }
    pair.0?.resume(returning: pair.1)
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    credentials.state.withLock { $0.identity = nil }
    invalidation.observe()
  }

  func invalidate(_ session: URLSession) async {
    await invalidation.wait { session.invalidateAndCancel() }
  }

}

func transfer(port: Int, anchor: SecCertificate, credentials: Credentials) async throws -> Outcome {
  let delegate = ProbeDelegate(port: port, anchor: anchor, credentials: credentials)
  let config = URLSessionConfiguration.ephemeral
  config.urlCredentialStorage = nil
  config.urlCache = nil
  config.httpCookieStorage = nil
  config.httpShouldSetCookies = false
  config.requestCachePolicy = .reloadIgnoringLocalCacheData
  config.waitsForConnectivity = false
  config.timeoutIntervalForRequest = 3
  config.timeoutIntervalForResource = 5
  config.httpMaximumConnectionsPerHost = 1
  config.tlsMinimumSupportedProtocolVersion = .TLSv13
  config.tlsMaximumSupportedProtocolVersion = .TLSv13
  config.connectionProxyDictionary = [
    "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
    "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
  ]
  let queue = OperationQueue()
  queue.maxConcurrentOperationCount = 1
  let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
  let url = URL(string: "https://127.0.0.1:\(port)/fixture")!
  let result = await withCheckedContinuation { continuation in
    delegate.state.withLock { $0.completion = continuation }
    session.dataTask(with: URLRequest(url: url)).resume()
  }
  await delegate.invalidate(session)
  return result
}

@main enum IdentityProbe {
  static func main() async {
    do { try await run() } catch {
      let stage: String
      if case ProbeError.rejected(let value) = error {
        stage = value
      } else {
        stage = "unexpected-local-failure"
      }
      try? FileHandle.standardError.write(
        contentsOf: Data("Identity prototype rejected: \(stage)\n".utf8))
      exit(1)
    }
  }

  static func run() async throws {
    try require(CommandLine.arguments.count == 2, "arguments")
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let key = try localKey()
    guard let publicKey = SecKeyCopyPublicKey(key) else { throw ProbeError.rejected("public-key") }
    let keyBytes = try publicBytes(publicKey)
    let publicSPKI = try P256.Signing.PublicKey(x963Representation: keyBytes).derRepresentation
    let csr = try MunieCSR.makeDER(privateKey: key, commonName: "Munie Memory Device")
    try csr.write(to: root.appendingPathComponent("device.csr.der"), options: .atomic)
    try emit([
      "event": "csr-ready", "keyBits": 256, "keyPermanent": false,
      "publicKeySHA256": digest(publicSPKI), "publicKeyEncoding": "spki-der",
      "csrSHA256": digest(csr),
    ])
    var line = Data()
    while let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty {
      if byte.first == 10 { break }
      try require(line.count < 4096, "configuration-limit")
      line.append(byte)
    }
    let config = try JSONDecoder().decode(Configuration.self, from: line)
    try require(
      (1024...65535).contains(config.port) && (1...16).contains(config.cases.count), "configuration"
    )
    let valid = try certificate(root, "valid.der")
    guard let certifiedKey = SecCertificateCopyKey(valid) else {
      throw ProbeError.rejected("certificate-key")
    }
    try require(try publicBytes(certifiedKey) == keyBytes, "certificate-key-mismatch")
    let wrongKey = try localKey()
    try require(SecIdentityCreate(nil, valid, wrongKey) == nil, "mismatched-identity-accepted")
    guard let identity = SecIdentityCreate(nil, valid, key) else {
      throw ProbeError.rejected("identity-create")
    }
    var exactCertificate: SecCertificate?
    try require(
      SecIdentityCopyCertificate(identity, &exactCertificate) == 0, "identity-certificate")
    try require(
      exactCertificate.map { SecCertificateCopyData($0) as Data } == SecCertificateCopyData(valid)
        as Data,
      "identity-leaf-mismatch")
    var identityKey: SecKey?
    try require(SecIdentityCopyPrivateKey(identity, &identityKey) == 0, "identity-private-key")
    guard let identityKey else { throw ProbeError.rejected("identity-private-key-missing") }
    let challenge = Data("munie-synthetic-possession-check".utf8)
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        identityKey, .ecdsaSignatureMessageX962SHA256,
        challenge as CFData, &error)
    else { throw ProbeError.rejected("identity-signature") }
    try require(
      SecKeyVerifySignature(
        publicKey, .ecdsaSignatureMessageX962SHA256,
        challenge as CFData, signature, &error), "identity-signature-verify")
    let credentials = Credentials(key: key)
    for item in config.cases {
      let der = try item.certificate.map { try fixtureFile(root, $0) }
      try credentials.install(der)
      let port = item.port ?? config.port
      try require((1024...65535).contains(port), "case-port")
      let result = try await transfer(
        port: port, anchor: certificate(root, item.anchor), credentials: credentials)
      var fields: [String: Any] = [
        "event": "result", "name": item.name,
        "bodyBytes": result.body.count, "serverChallenges": result.serverChallenges,
        "clientChallenges": result.clientChallenges, "trustRejected": result.trustRejected,
        "overflow": result.overflow, "redirectRejected": result.redirect, "invalidated": true,
      ]
      if let status = result.status { fields["httpStatus"] = status }
      if let code = result.errorCode { fields["errorCode"] = code }
      if let tls = result.tlsProtocol { fields["tlsProtocol"] = tls }
      if let proxy = result.proxy { fields["proxy"] = proxy }
      if !result.body.isEmpty {
        let reply = try JSONSerialization.jsonObject(with: result.body) as? [String: String]
        guard let reply, Set(reply.keys) == ["state", "peer"],
          ["accepted", "denied"].contains(reply["state"] ?? ""),
          reply["peer"]?.count == 64
        else { throw ProbeError.rejected("reply") }
        fields["state"] = reply["state"]
        fields["peer"] = reply["peer"]
      }
      try emit(fields)
    }
    try emit([
      "event": "done", "sessionsInvalidated": config.cases.count,
      "certificateKeyMatched": true, "identityLeafMatched": true,
      "identityPossessionVerified": true, "mismatchedIdentityRejected": true,
      "keychainUsed": false, "privateKeyExported": false,
    ])
  }
}
