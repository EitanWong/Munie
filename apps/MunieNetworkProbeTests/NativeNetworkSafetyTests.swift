import Foundation
import Security
import Testing

@testable import MunieNativeNetworkProbe

private let fixturePort = 60443

private func configuration(
  port: Int = fixturePort, caPath: String = "/synthetic-fixture/ca.der",
  identityPath: String? = nil, passphrase: String? = nil
) -> FixtureConfiguration {
  FixtureConfiguration(
    port: port, caDERPath: caPath, identityPKCS12Path: identityPath, passphrase: passphrase)
}

@Suite("Native network fixture safety")
struct NativeNetworkSafetyTests {
  @Test(arguments: [1024, 65535])
  func validPortsHaveOnlyTheFourLoopbackHTTPSRoutes(port: Int) throws {
    let value = configuration(port: port)
    try value.validate()
    for route in ["submit", "redirect", "oversized", "slow"] {
      let endpoint = try value.endpoint(path: route)
      #expect(endpoint.scheme == "https")
      #expect(endpoint.host == "127.0.0.1")
      #expect(endpoint.port == port)
      #expect(endpoint.path == "/fixture/\(route)")
      #expect(endpoint.query == nil && endpoint.fragment == nil && endpoint.user == nil)
    }
  }

  @Test(arguments: [-1, 0, 80, 1023, 65536, Int.max])
  func invalidPortsCannotReachAnEndpoint(port: Int) {
    let value = configuration(port: port)
    #expect(throws: ProbeFailure.self) { try value.validate() }
    #expect(throws: ProbeFailure.self) { try value.endpoint(path: "submit") }
  }

  @Test
  func configurationRequiresAbsolutePathsAndPairedIdentityInputs() throws {
    for invalid in [
      configuration(caPath: "ca.der"),
      configuration(identityPath: "identity.p12", passphrase: "fixture"),
      configuration(identityPath: "/synthetic-fixture/identity.p12"),
      configuration(passphrase: "fixture-passphrase"),
    ] {
      #expect(throws: ProbeFailure.self) { try invalid.validate() }
    }
    try configuration(
      identityPath: "/synthetic-fixture/identity.p12", passphrase: "fixture-passphrase"
    ).validate()
  }

  @Test
  func validRepliesExposeOnlyTheFixedAcceptanceOrDenialFields() throws {
    for ordinal in [1, 4] {
      let data = Data("{\"state\":\"fixture-accepted\",\"ordinal\":\(ordinal)}".utf8)
      let reply = try parseFixtureReply(data)
      #expect(Set(reply.keys) == ["state", "ordinal"])
      #expect(reply["state"] as? String == "fixture-accepted")
      #expect(reply["ordinal"] as? Int == ordinal)
    }
    for error in ["device-denied", "project-denied", "request-conflict", "fixture-capacity"] {
      let reply = try parseFixtureReply(Data("{\"error\":\"\(error)\"}".utf8))
      #expect(Set(reply.keys) == ["fixtureError"])
      #expect(reply["fixtureError"] as? String == error)
    }
  }

  @Test(arguments: [
    #"{"state":"fixture-accepted","ordinal":true}"#,
    #"{"state":"fixture-accepted","ordinal":1.0}"#,
    #"{"state":"fixture-accepted","ordinal":1e0}"#,
    #"{"state":"fixture-accepted","ordinal":null}"#,
    #"{"state":"fixture-accepted","ordinal":"1"}"#,
    #"{"state":"fixture-accepted","ordinal":0}"#,
    #"{"state":"fixture-accepted","ordinal":5}"#,
    #"{"state":"fixture-accepted","ordinal":1,"token":"synthetic-private"}"#,
    #"{"state":"fixture-accepted","ordinal":1,"ordinal":2}"#,
    #"{"state":"fixture-accepted","ordinal":1,"\u006frdinal":2}"#,
    #"{"state":"fixture-accepted","ordinal":1,"error":"device-denied"}"#,
    #"{"error":"device-denied","payload":"synthetic-private"}"#,
    #"{"error":"device-denied","error":"project-denied"}"#,
    #"{"error":"unknown"}"#, #"{"error":true}"#, "null", "[]",
  ])
  func malformedRepliesCannotBeSanitizedIntoAcceptedEvidence(json: String) {
    #expect(throws: (any Error).self) { try parseFixtureReply(Data(json.utf8)) }
  }

  @Test
  func responseParserRejectsInvalidUTF8AndOversizedInput() {
    #expect(throws: (any Error).self) { try parseFixtureReply(Data([0xFF])) }
    #expect(throws: (any Error).self) {
      try parseFixtureReply(Data(repeating: 0x20, count: 2049))
    }
  }

  @Test(arguments: [
    "", "../submit", "submit/", "submit?token=synthetic", "submit#fragment",
    "https://other.invalid/fixture/submit", "%73ubmit", "Submit", "/submit",
  ])
  func routeInputCannotChangeTheAuthorityOrRequestTarget(route: String) {
    #expect(throws: ProbeFailure.self) { try configuration().endpoint(path: route) }
  }

  @Test
  func sessionHasNoSharedStateOrImplicitProxyAndUsesBoundedTLS13() throws {
    let delegate = try makeDelegate()
    let session = fixtureSession(delegate: delegate)
    defer { session.invalidateAndCancel() }
    let value = session.configuration
    #expect(value.identifier == nil)
    #expect(value.urlCache == nil && value.httpCookieStorage == nil)
    #expect(value.urlCredentialStorage == nil && !value.httpShouldSetCookies)
    #expect(value.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(value.tlsMinimumSupportedProtocolVersion == .TLSv13)
    #expect(value.tlsMaximumSupportedProtocolVersion == .TLSv13)
    #expect(!value.waitsForConnectivity)
    #expect(value.timeoutIntervalForRequest > 0 && value.timeoutIntervalForRequest <= 3)
    #expect(value.timeoutIntervalForResource > 0 && value.timeoutIntervalForResource <= 5)
    let proxies = try #require(value.connectionProxyDictionary)
    for proxy in [
      "HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable",
      "ProxyAutoDiscoveryEnable",
    ] {
      #expect((proxies[proxy] as? NSNumber)?.intValue == 0)
    }
  }

  @Test(arguments: ChallengeBoundary.allCases)
  func outOfScopeChallengesCannotReceiveCredentials(boundary: ChallengeBoundary) async throws {
    let delegate = try makeDelegate()
    let result = await transferResult(delegate: delegate) { session, _ in
      var completed = false
      delegate.urlSession(session, didReceive: boundary.challenge()) { disposition, credential in
        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
        completed = true
      }
      #expect(completed)
    }
    // A wrong endpoint must be rejected before entering either credential path.
    #expect(result.clientChallenges == 0 && result.serverChallenges == 0)
  }

  @Test
  func clientCertificateChallengeWithoutIdentityCannotReuseProposedCredentials() async throws {
    #expect(try importFixtureIdentity(configuration()) == nil)
    let delegate = try makeDelegate()
    #expect(!delegate.hasIdentity)
    let result = await transferResult(delegate: delegate) { session, _ in
      delegate.urlSession(session, didReceive: challenge()) { disposition, credential in
        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
      }
    }
    #expect(result.clientChallenges == 1)
    #expect(!delegate.hasIdentity)
  }

  @Test
  func serverTrustChallengeWithoutTrustIsRejected() async throws {
    let delegate = try makeDelegate()
    let result = await transferResult(delegate: delegate) { session, _ in
      delegate.urlSession(
        session, didReceive: challenge(method: NSURLAuthenticationMethodServerTrust)
      ) { disposition, credential in
        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
      }
    }
    #expect(result.serverChallenges == 1 && result.trustRejected == 1)
  }

  @Test(arguments: [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest])
  func unsupportedAuthenticationCannotFallBackToAStoredCredential(method: String) async throws {
    let delegate = try makeDelegate()
    let result = await transferResult(delegate: delegate) { session, _ in
      delegate.urlSession(session, didReceive: challenge(method: method)) {
        disposition, credential in
        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
      }
    }
    #expect(result.clientChallenges == 0 && result.serverChallenges == 0)
  }

  @Test(arguments: ["https://other.invalid/collect", "http://127.0.0.1:60443/fixture/submit"])
  func redirectsNeverForwardTheOriginalRequest(destination: String) async throws {
    let delegate = try makeDelegate()
    let result = await transferResult(delegate: delegate) { session, task in
      let source = task.originalRequest!.url!
      let response = HTTPURLResponse(
        url: source, statusCode: 307, httpVersion: "HTTP/1.1",
        headerFields: ["Location": destination])!
      var request = URLRequest(url: URL(string: destination)!)
      request.httpBody = Data("synthetic-private-request".utf8)
      var completed = false
      delegate.urlSession(
        session, task: task, willPerformHTTPRedirection: response, newRequest: request
      ) { redirected in
        #expect(redirected == nil)
        completed = true
      }
      #expect(completed)
    }
    #expect(result.redirectRejected && result.body.isEmpty)
  }

  @Test
  func declaredOversizeIsRejectedBeforeAnyResponseBytesAreStored() async throws {
    let delegate = try makeDelegate()
    let result = await transferResult(delegate: delegate) { session, task in
      let response = HTTPURLResponse(
        url: task.originalRequest!.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "2049"])!
      delegate.urlSession(session, dataTask: task, didReceive: response) { disposition in
        #expect(disposition == .cancel)
      }
      delegate.urlSession(session, dataTask: task, didReceive: Data([0x61]))
    }
    #expect(result.overflow && result.body.isEmpty)
  }

  @Test
  func cancellationAtResponseHeadersRetainsStatusAndDiscardsLateBodyCallbacks() async throws {
    let delegate = try makeDelegate()
    let cancelled = await transferResult(delegate: delegate, cancelOnResponse: true) {
      session, task in
      let response = HTTPURLResponse(
        url: task.originalRequest!.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "1"])!
      delegate.urlSession(session, dataTask: task, didReceive: response) { disposition in
        #expect(disposition == .cancel)
      }
      delegate.urlSession(session, dataTask: task, didReceive: Data([0x61]))
    }
    #expect(cancelled.status == 200 && cancelled.cancelledOnResponse)
    #expect(cancelled.body.isEmpty && !cancelled.overflow)

    // Cancellation belongs to this transfer; the next ordinary response remains usable.
    let next = await transferResult(delegate: delegate) { session, task in
      let response = HTTPURLResponse(
        url: task.originalRequest!.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "1"])!
      delegate.urlSession(session, dataTask: task, didReceive: response) { disposition in
        #expect(disposition == .allow)
      }
      delegate.urlSession(session, dataTask: task, didReceive: Data([0x62]))
    }
    #expect(next.status == 200 && !next.cancelledOnResponse)
    #expect(next.body == Data([0x62]))
  }

  @Test
  func unknownLengthResponseMayReachButNeverExceedTheByteLimit() async throws {
    let delegate = try makeDelegate()
    let result = await transferResult(delegate: delegate) { session, task in
      let response = HTTPURLResponse(
        url: task.originalRequest!.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
      )!
      #expect(response.expectedContentLength == -1)
      delegate.urlSession(session, dataTask: task, didReceive: response) { disposition in
        #expect(disposition == .allow)
      }
      delegate.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x61, count: 2047))
      delegate.urlSession(session, dataTask: task, didReceive: Data([0x62]))
    }
    #expect(!result.overflow && result.body.count == 2048)
    #expect(result.body.last == 0x62)
  }

  @Test
  func crossingTheLimitDiscardsTheWholeChunkAndLateCallbacksCannotAppend() async throws {
    let delegate = try makeDelegate()
    let result = await transferResult(delegate: delegate) { session, task in
      delegate.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x61, count: 2047))
      delegate.urlSession(session, dataTask: task, didReceive: Data([0x62, 0x63]))
      delegate.urlSession(session, dataTask: task, didReceive: Data([0x64]))
      for _ in 0..<3 {
        delegate.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x65, count: 4096))
      }
    }
    #expect(result.overflow)
    #expect(result.body == Data(repeating: 0x61, count: 2047))
  }

  @Test
  func nonHTTPResponsesCannotEnterTheBodyReader() async throws {
    let delegate = try makeDelegate()
    let result = await transferResult(delegate: delegate) { session, task in
      let response = URLResponse(
        url: task.originalRequest!.url!, mimeType: "application/json", expectedContentLength: 5,
        textEncodingName: nil)
      delegate.urlSession(session, dataTask: task, didReceive: response) { disposition in
        #expect(disposition == .cancel)
      }
    }
    #expect(result.status == nil && result.body.isEmpty)
  }

  @Test(arguments: TrustBoundary.allCases)
  func actualSecTrustRequiresTheLoopbackNameAndIndependentAnchor(boundary: TrustBoundary) throws {
    let certificate = try boundary.server.certificate()
    let anchor = try boundary.anchor.certificate()
    var optionalTrust: SecTrust?
    #expect(
      SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &optionalTrust)
        == errSecSuccess)
    let trust = try #require(optionalTrust)
    // Fixed inside the leaves' 2026-11-17...2027-11-17 validity; no wall-clock dependency.
    #expect(SecTrustSetVerifyDate(trust, Date(timeIntervalSince1970: 1_800_000_000) as CFDate) == 0)
    #expect(validateFixtureServerTrust(trust, anchor: anchor) == boundary.shouldTrust)
  }
}

private func makeDelegate() throws -> FixtureSessionDelegate {
  FixtureSessionDelegate(
    port: fixturePort, anchor: try FixtureCertificate.trustedRoot.certificate(), identity: nil)
}

private func transferResult(
  delegate: FixtureSessionDelegate,
  cancelOnResponse: Bool = false,
  exercise: (URLSession, URLSessionDataTask) -> Void
) async -> TransferResult {
  // No delegate and no resume: cancellation exercised by callbacks cannot trigger a
  // second completion on the tested delegate, perform I/O or consult personal storage.
  let session = URLSession(configuration: .ephemeral)
  defer { session.invalidateAndCancel() }
  let task = session.dataTask(with: URL(string: "https://127.0.0.1:\(fixturePort)/fixture/submit")!)
  return await withCheckedContinuation { continuation in
    delegate.begin(continuation, cancelOnResponse: cancelOnResponse)
    exercise(session, task)
    delegate.urlSession(session, task: task, didCompleteWithError: nil)
  }
}

enum ChallengeBoundary: CaseIterable, Sendable {
  case wrongHost, wrongPort, proxy, wrongProtocol, repeated

  func challenge() -> URLAuthenticationChallenge {
    switch self {
    case .wrongHost: makeChallenge(host: "other.invalid")
    case .wrongPort: makeChallenge(port: fixturePort + 1)
    case .wrongProtocol: makeChallenge(protocolName: "http")
    case .repeated: makeChallenge(previousFailures: 1)
    case .proxy:
      makeChallenge(
        space: URLProtectionSpace(
          proxyHost: "127.0.0.1", port: fixturePort, type: NSURLProtectionSpaceHTTPSProxy,
          realm: nil, authenticationMethod: NSURLAuthenticationMethodClientCertificate))
    }
  }
}

private func challenge(method: String = NSURLAuthenticationMethodClientCertificate)
  -> URLAuthenticationChallenge
{
  makeChallenge(method: method)
}

private func makeChallenge(
  host: String = "127.0.0.1", port: Int = fixturePort, protocolName: String = "https",
  method: String = NSURLAuthenticationMethodClientCertificate, previousFailures: Int = 0,
  space: URLProtectionSpace? = nil
) -> URLAuthenticationChallenge {
  URLAuthenticationChallenge(
    protectionSpace: space
      ?? URLProtectionSpace(
        host: host, port: port, protocol: protocolName, realm: nil, authenticationMethod: method),
    proposedCredential: URLCredential(
      user: "synthetic-proposed-user", password: "synthetic-proposed-password", persistence: .none),
    previousFailureCount: previousFailures, failureResponse: nil, error: nil,
    sender: ChallengeSender())
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
  func cancel(_ challenge: URLAuthenticationChallenge) {}
  func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
  func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

enum TrustBoundary: CaseIterable, Sendable {
  case expectedServer, wrongHostname, unrelatedAnchor

  var server: FixtureCertificate { self == .wrongHostname ? .wrongHostServer : .loopbackServer }
  var anchor: FixtureCertificate { self == .unrelatedAnchor ? .foreignRoot : .trustedRoot }
  var shouldTrust: Bool { self == .expectedServer }
}
