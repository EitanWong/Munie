#if DEBUG
import CryptoKit
import Foundation
import os
import XCTest
@testable import MunieRemodex

nonisolated final class ManagedRelayPhoneConnectorTests: XCTestCase {
  private typealias Connector = ManagedRelayPhoneConnector
  private static let hintID = "8b12dbaf-9fb1-4e88-b416-f0752e4ca4d1"

  func testRejectsOriginsOtherThanExactIPv4LoopbackWithExplicitCanonicalPort() throws {
    let admission = try credential()
    for origin in [
      "http://localhost:1234", "https://127.0.0.1:1234", "http://127.1:1234", "http://[::1]:1234",
      "http://127.0.0.2:1234", "http://user@127.0.0.1:1234", "http://127.0.0.1",
      "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:01234",
      "http://127.0.0.1:+1234", "http://127.0.0.1:1234/", "http://127.0.0.1:1234?",
      "http://127.0.0.1:1234#", "http://127.0.0.1:1234@localhost", "http://127.0.0.1:1234\n",
    ] {
      XCTAssertThrowsError(try Connector(origin: origin, admission: admission), origin) {
        XCTAssertEqual($0 as? Connector.Failure, .invalidLoopbackOrigin)
      }
    }
    for port in [1, 80, 65_535] {
      XCTAssertNoThrow(try Connector(origin: "http://127.0.0.1:\(port)", admission: admission))
    }
  }

  func testUsesExactEndpointsAndHandsOffSameOwnedPairAfterOneHint() async throws {
    let fixture = try Fixture(admission: credential())
    let challenge = try fixture.challenge()
    fixture.reply(.http(body: challenge, headers: ["Set-Cookie": "unexpected=secret"]))

    let captured = OSAllocatedUnfairLock(initialState: [SocketObservation]())
    let text = hint()
    let connector = try fixture.connector { session, task in
      captured.withLock { $0.append(SocketObservation(session: session, task: task, limit: task.maximumMessageSize)) }
      return .string(text)
    }
    let bootstrap = try await connector.connect()
    defer { bootstrap.cancel() }

    let requests = fixture.requests
    XCTAssertEqual(requests.count, 1)
    let post = try XCTUnwrap(requests.first)
    XCTAssertEqual(post.url?.absoluteString, fixture.origin + "/v1/managed/challenge")
    XCTAssertEqual(post.httpMethod, "POST")
    XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertTrue(munieHeaders(post).isEmpty)
    let posted = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody(post)) as? [String: String])
    XCTAssertEqual(posted, ["role": "phone", "macKey": fixture.admission.macKey, "phoneKey": fixture.admission.phoneKey])

    let sockets = captured.withLock { $0 }
    XCTAssertEqual(sockets.count, 1)
    let socket = try XCTUnwrap(sockets.first)
    XCTAssertTrue(bootstrap.session === socket.session)
    XCTAssertTrue(bootstrap.webSocketTask === socket.task)
    XCTAssertEqual(bootstrap.untrustedSessionIDHint, Self.hintID)
    XCTAssertEqual(socket.limit, 1024 * 1024)
    XCTAssertEqual(bootstrap.webSocketTask.maximumMessageSize, 1024 * 1024)
    let upgrade = try XCTUnwrap(socket.task.originalRequest)
    XCTAssertEqual(upgrade.url?.absoluteString, "ws://127.0.0.1:\(fixture.port)/v1/managed/connect")
    XCTAssertEqual(upgrade.httpMethod, "GET")
    let headers = munieHeaders(upgrade)
    XCTAssertEqual(Set(headers.keys), ["x-munie-role", "x-munie-challenge", "x-munie-proof"])
    XCTAssertEqual(headers["x-munie-role"], "phone")
    XCTAssertEqual(headers["x-munie-challenge"], String(repeating: "A", count: 43))
    XCTAssertNil(upgrade.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(upgrade.value(forHTTPHeaderField: "Authorization"))
    try assertSignature(try XCTUnwrap(headers["x-munie-proof"]), challenge: challenge)
    XCTAssertNil(socket.session.configuration.httpCookieStorage)
    XCTAssertFalse(socket.session.configuration.httpShouldSetCookies)
    XCTAssertNil(socket.session.configuration.urlCache)
    XCTAssertNil(socket.session.configuration.urlCredentialStorage)
    XCTAssertEqual(socket.session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(socket.task.state, .suspended) // Mock never resumes; connector did not cancel ownership.
    bootstrap.cancel()
    await assertCancelled(socket.task)
  }

  func testRejectsChallengeRedirectAndAmbiguousForbiddenBeforeUpgrade() async throws {
    let fixture = try Fixture(admission: credential())
    fixture.reply(.http(status: 307, headers: ["Location": fixture.origin + "/other"]))
    await expect(try fixture.connector(), .redirectRejected(.challenge))
    fixture.reply(.http(status: 403))
    await expect(try fixture.connector(), .admissionForbidden(.challenge))
    XCTAssertEqual(fixture.requests.map(\.url?.path), Array(repeating: "/v1/managed/challenge", count: 2))
  }

  func testRejectsOversizedStreamAndUntrustedChallengesBeforeUpgrade() async throws {
    let fixture = try Fixture(admission: credential())
    fixture.reply(.http(body: Data(repeating: 32, count: 1025), complete: false))
    await expect(try fixture.connector(), .invalidChallenge)
    fixture.reply(.http(headers: ["Content-Length": "1025"], complete: false))
    await expect(try fixture.connector(), .invalidChallenge)
    for patch in [["role": "mac"], ["macKey": fixture.admission.phoneKey], ["expiresAt": 1], ["generation": ""]] {
      fixture.reply(.http(body: try fixture.challenge(patch)))
      await expect(try fixture.connector(), .invalidChallenge)
    }
  }

  func testMapsKnownOutagesAndFailsClosedOnOpaqueUpgradeFailures() async throws {
    let fixture = try Fixture(admission: credential())
    fixture.reply(.failure(.cannotConnectToHost))
    await expect(try fixture.connector(), .transientUnavailable(.challenge))
    fixture.reply(.http(body: try fixture.challenge()))
    await expect(try fixture.connector { _, _ in throw URLError(.cannotConnectToHost) },
      .transientUnavailable(.bootstrap))
    await expect(try fixture.connector { _, _ in throw URLError(.badServerResponse) }, .unexpectedResponse(.bootstrap))
    await expect(try fixture.connector { _, _ in throw URLError(.networkConnectionLost) }, .unexpectedResponse(.bootstrap))
    XCTAssertEqual(Connector.classify(URLError(.cannotConnectToHost), stage: .bootstrap, redirected: false, status: 403),
      .admissionForbidden(.bootstrap))
    XCTAssertEqual(Connector.classify(URLError(.networkConnectionLost), stage: .bootstrap, redirected: false,
      status: 101, closeCode: 4004), .transientUnavailable(.bootstrap))
    XCTAssertEqual(Connector.classify(URLError(.networkConnectionLost), stage: .bootstrap, redirected: false,
      status: 101, closeCode: 1009), .unexpectedResponse(.bootstrap))
  }

  func testRejectsFirstMessageExceptExactKindAndCanonicalUUID() async throws {
    let fixture = try Fixture(admission: credential())
    fixture.reply(.http(body: try fixture.challenge()))
    for text in [hint(kind: "secureReady"), hint(id: Self.hintID.uppercased()), hint(id: "fixture-session"),
      hint() + String(repeating: " ", count: 1024), "{", "{}"]
    {
      await expect(try fixture.connector { _, _ in .string(text) }, .invalidRouteHint)
    }
    let binary = Data(hint().utf8)
    await expect(try fixture.connector { _, _ in .data(binary) }, .invalidRouteHint)
  }

  func testDeadlineCancelsChallengeAndBootstrapWork() async throws {
    let fixture = try Fixture(admission: credential())
    fixture.reply(.http(complete: false))
    await expect(try fixture.connector(challengeDeadline: .milliseconds(100)), .transientUnavailable(.challenge))
    await fulfillment(of: [fixture.stopObserved], timeout: 2)

    fixture.reply(.http(body: try fixture.challenge()))
    let socket = OSAllocatedUnfairLock<URLSessionWebSocketTask?>(initialState: nil)
    let connector = try fixture.connector(bootstrapDeadline: .milliseconds(100)) { _, task in
      socket.withLock { $0 = task }
      try await Task.sleep(for: .seconds(10))
      return .string("never")
    }
    await expect(connector, .transientUnavailable(.bootstrap))
    await assertCancelled(try XCTUnwrap(socket.withLock { $0 }))
  }

  func testCallerCancellationDuringBootstrapIsNotAnOutage() async throws {
    let fixture = try Fixture(admission: credential())
    fixture.reply(.http(body: try fixture.challenge()))
    let started = XCTestExpectation(description: "First receive began")
    let socket = OSAllocatedUnfairLock<URLSessionWebSocketTask?>(initialState: nil)
    let connector = try fixture.connector { _, task in
      socket.withLock { $0 = task }
      started.fulfill()
      try await Task.sleep(for: .seconds(10))
      return .string("never")
    }
    let attempt = Task { try await connector.connect() }
    await fulfillment(of: [started], timeout: 2)
    attempt.cancel()
    do {
      try await attempt.value.cancel()
      XCTFail("Cancelled attempt returned a socket")
    } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    await assertCancelled(try XCTUnwrap(socket.withLock { $0 }))
  }

  func testSessionPolicyNeverFollowsProofRedirect() throws {
    let policy = Connector.SessionPolicy()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let origin = try XCTUnwrap(URL(string: "ws://127.0.0.1:4321/v1/managed/connect"))
    let socket = session.webSocketTask(with: origin)
    var redirect = URLRequest(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:4322/elsewhere")))
    redirect.setValue("fixture-proof", forHTTPHeaderField: "x-munie-proof")
    let response = try XCTUnwrap(HTTPURLResponse(url: origin, statusCode: 307, httpVersion: nil, headerFields: nil))
    let declined = XCTestExpectation(description: "No redirected request")
    policy.urlSession(session, task: socket, willPerformHTTPRedirection: response, newRequest: redirect) { result in
      XCTAssertNil(result)
      declined.fulfill()
    }
    XCTAssertEqual(XCTWaiter.wait(for: [declined], timeout: 1), .completed)
    XCTAssertTrue(policy.redirected)
  }

  private func expect(_ connector: Connector, _ expected: Connector.Failure,
    file: StaticString = #filePath, line: UInt = #line) async
  {
    do {
      try await connector.connect().cancel()
      XCTFail("Unexpectedly returned a socket", file: file, line: line)
    } catch { XCTAssertEqual(error as? Connector.Failure, expected, "\(error)", file: file, line: line) }
  }

  private func assertCancelled(_ task: URLSessionTask, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = ContinuousClock.now + .seconds(1)
    while task.state == .suspended, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(task.state == .canceling || task.state == .completed, "\(task.state)", file: file, line: line)
  }

  private func munieHeaders(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).compactMap { key, value in
      key.lowercased().hasPrefix("x-munie-") ? (key.lowercased(), value) : nil
    })
  }

  private func assertSignature(_ signature: String, challenge: Data) throws {
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: challenge) as? [String: Any])
    let transcript = try JSONSerialization.data(withJSONObject: ["munie-managed-relay-admission-v1"] +
      ["audience", "role", "macKey", "phoneKey", "id", "generation", "expiresAt"].map { try XCTUnwrap(fields[$0]) })
    XCTAssertEqual(signature.utf8.count, 86)
    let bytes = try XCTUnwrap(Data(base64Encoded:
      signature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="))
    let phone = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
    XCTAssertTrue(phone.publicKey.isValidSignature(bytes, for: transcript))
  }

  private func hint(kind: String = "managedRouteReady", id: String = hintID) -> String {
    "{\"kind\":\"\(kind)\",\"sessionId\":\"\(id)\"}"
  }

  private func credential() throws -> ManagedRelayPhoneAdmission {
    let phone = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
    let mac = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(32..<64))
    return try ManagedRelayPhoneAdmission(
      identity: CodexPhoneIdentityState(phoneDeviceId: "fixture-phone",
        phoneIdentityPrivateKey: phone.rawRepresentation.base64EncodedString(),
        phoneIdentityPublicKey: phone.publicKey.rawRepresentation.base64EncodedString()),
      trustedMac: CodexTrustedMacRecord(macDeviceId: "fixture-mac",
        macIdentityPublicKey: mac.publicKey.rawRepresentation.base64EncodedString(), lastPairedAt: .distantPast))
  }

  private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 1024)
    let count = stream.read(&buffer, maxLength: buffer.count)
    XCTAssertGreaterThan(count, 0)
    return Data(buffer.prefix(max(count, 0)))
  }

  nonisolated private struct SocketObservation: Sendable {
    let session: URLSession
    let task: URLSessionWebSocketTask
    let limit: Int
  }

  private final class Fixture: Sendable {
    private struct State: Sendable {
      var requests: [URLRequest] = []
      var reply: StubReply = .failure(.badServerResponse)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let stopObserved = XCTestExpectation(description: "Cancelled challenge I/O")
    let admission: ManagedRelayPhoneAdmission
    let port: Int
    var origin: String { "http://127.0.0.1:\(port)" }
    var requests: [URLRequest] { state.withLock { $0.requests } }

    init(admission: ManagedRelayPhoneAdmission) {
      self.admission = admission
      port = ChallengeProtocol.registry.withLock { registry in
        defer { registry.nextPort += 1 }
        return registry.nextPort
      }
      let state = self.state
      let stopObserved = self.stopObserved
      ChallengeProtocol.registry.withLock {
        $0.responders[port] = { request in
          state.withLock {
            $0.requests.append(request)
            return ($0.reply, stopObserved)
          }
        }
      }
    }

    deinit { ChallengeProtocol.registry.withLock { $0.responders[port] = nil } }

    func reply(_ reply: StubReply) { state.withLock { $0.reply = reply } }

    func connector(challengeDeadline: Duration = .seconds(3), bootstrapDeadline: Duration = .seconds(3),
      receive: @escaping @Sendable (URLSession, URLSessionWebSocketTask) async throws
        -> URLSessionWebSocketTask.Message = { _, _ in
          XCTFail("Invalid challenge must not create a proof-bearing socket")
          throw URLError(.badServerResponse)
        }) throws -> Connector
    {
      try Connector(origin: origin, admission: admission,
        io: .init(challengeProtocol: ChallengeProtocol.self, challengeDeadline: challengeDeadline,
          bootstrapDeadline: bootstrapDeadline, receiveFirstMessage: receive))
    }

    func challenge(_ overrides: [String: Any] = [:]) throws -> Data {
      var fields: [String: Any] = [
        "role": "phone", "audience": ManagedRelayPhoneAdmission.audience,
        "phoneKey": admission.phoneKey, "macKey": admission.macKey,
        "id": String(repeating: "A", count: 43), "generation": String(repeating: "E", count: 43),
        "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 15_000,
      ]
      fields.merge(overrides) { _, replacement in replacement }
      return try JSONSerialization.data(withJSONObject: fields)
    }
  }

  nonisolated private enum StubReply: Sendable {
    case http(status: Int = 200, body: Data = Data(), headers: [String: String] = [:], complete: Bool = true)
    case failure(URLError.Code)
  }

  nonisolated private final class ChallengeProtocol: URLProtocol, @unchecked Sendable {
    struct Registry {
      var nextPort = 50_000
      var responders: [Int: @Sendable (URLRequest) -> (StubReply, XCTestExpectation)] = [:]
    }
    static let registry = OSAllocatedUnfairLock(initialState: Registry())
    private let stopObserved = OSAllocatedUnfairLock<XCTestExpectation?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "http" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url, let port = url.port,
        let respond = Self.registry.withLock({ $0.responders[port] })
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      let (reply, stopped) = respond(request)
      switch reply {
      case .http(let status, let body, let headers, let complete):
        let fields = ["Content-Type": "application/json"].merging(headers) { _, override in override }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)
        else { return }
        if !complete { stopObserved.withLock { $0 = stopped } }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        if complete { client?.urlProtocolDidFinishLoading(self) }
      case .failure(let code):
        client?.urlProtocol(self, didFailWithError: URLError(code))
      }
    }

    override func stopLoading() {
      stopObserved.withLock {
        $0?.fulfill()
        $0 = nil
      }
    }
  }
}
#endif
