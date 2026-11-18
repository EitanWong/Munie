#if DEBUG
import CFNetwork
import Foundation
import os

/// Developer-only bootstrap for the managed relay pilot. This does not authenticate the Mac.
nonisolated struct ManagedRelayPhoneConnector: Sendable {
  enum Stage: Equatable, Sendable {
    case challenge
    case bootstrap
  }

  enum Failure: Error, Equatable {
    case invalidLoopbackOrigin
    case transientUnavailable(Stage)
    // The pilot uses 403 for both no current route and denied admission. Do not infer revocation.
    case admissionForbidden(Stage)
    case redirectRejected(Stage)
    case unexpectedResponse(Stage)
    case invalidChallenge
    case invalidRouteHint
  }

  struct Bootstrap: Sendable {
    /// A routing hint only. Do not publish readiness or persist it before the v2 handshake.
    let untrustedSessionIDHint: String
    let session: URLSession
    let webSocketTask: URLSessionWebSocketTask

    /// The caller owns cancellation, including after transferring this pair to a transport.
    func cancel() {
      webSocketTask.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
    }
  }

  private static let maximumHintBytes = 1024
  private static let maximumRoutedMessageBytes = 1024 * 1024 // Node pilot MAX_FRAME
  private let challengeURL: URL
  private let upgradeURL: URL
  private let admission: ManagedRelayPhoneAdmission
  private let io: IO

  // Only the I/O needed by this bootstrap is injectable; production still constructs both URLs.
  struct IO: Sendable {
    let challengeProtocol: URLProtocol.Type?
    let challengeDeadline: Duration
    let bootstrapDeadline: Duration
    let receiveFirstMessage: @Sendable (URLSession, URLSessionWebSocketTask) async throws
      -> URLSessionWebSocketTask.Message

    static let live = Self(challengeProtocol: nil, challengeDeadline: .seconds(3),
      bootstrapDeadline: .seconds(5)) { _, task in
      task.resume()
      return try await task.receive()
    }
  }

  init(origin: String, admission: ManagedRelayPhoneAdmission, io: IO = .live) throws {
    let prefix = "http://127.0.0.1:"
    let port = origin.dropFirst(prefix.count)
    guard origin.hasPrefix(prefix), (1...5).contains(port.utf8.count),
      port.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(port),
      (1...65_535).contains(number), String(number) == port,
      let challengeURL = URL(string: "\(origin)/v1/managed/challenge"),
      let upgradeURL = URL(string: "ws://127.0.0.1:\(port)/v1/managed/connect")
    else { throw Failure.invalidLoopbackOrigin }
    self.challengeURL = challengeURL
    self.upgradeURL = upgradeURL
    self.admission = admission
    self.io = io
  }

  func connect() async throws -> Bootstrap {
    try Task.checkCancellation()
    let policy = SessionPolicy()
    let session = URLSession(configuration: configuration(), delegate: policy, delegateQueue: nil)
    var handedOff = false
    defer { if !handedOff { policy.cancel(session) } }

    return try await withTaskCancellationHandler {
      var challenge = URLRequest(url: challengeURL)
      challenge.httpMethod = "POST"
      challenge.setValue("application/json", forHTTPHeaderField: "Content-Type")
      challenge.httpBody = try admission.challengeRequestBody()
      let request = challenge
      let challengeBytes: Data
      do {
        challengeBytes = try await Self.bounded(io.challengeDeadline, stage: .challenge, cancel: {
          policy.cancel(session)
        }) {
          try await policy.readChallenge(request, on: session)
        }
      } catch {
        try Task.checkCancellation()
        throw Self.classify(error, stage: .challenge, redirected: policy.redirected)
      }

      let proof: ManagedRelayPhoneAdmission.Proof
      do { proof = try admission.proof(for: challengeBytes) }
      catch { throw Failure.invalidChallenge }
      try Task.checkCancellation()
      var upgrade = URLRequest(url: upgradeURL)
      for (field, value) in proof.upgradeHeaders { upgrade.setValue(value, forHTTPHeaderField: field) }
      let task = try policy.makeWebSocketTask(upgrade, on: session)
      // Foundation applies this wire limit when the task starts; the first hint has a smaller decode limit.
      task.maximumMessageSize = Self.maximumRoutedMessageBytes

      let message: URLSessionWebSocketTask.Message
      do {
        message = try await Self.bounded(io.bootstrapDeadline, stage: .bootstrap, cancel: {
          policy.cancel(session)
        }) {
          try await io.receiveFirstMessage(session, task)
        }
      } catch {
        try Task.checkCancellation()
        throw Self.classify(error, stage: .bootstrap, redirected: policy.redirected,
          status: (task.response as? HTTPURLResponse)?.statusCode, closeCode: task.closeCode.rawValue)
      }
      try Task.checkCancellation()
      guard !policy.redirected else { throw Failure.redirectRejected(.bootstrap) }
      guard case .string(let text) = message, text.utf8.count <= Self.maximumHintBytes,
        let hint = try? JSONDecoder().decode(RouteHint.self, from: Data(text.utf8)),
        hint.kind == "managedRouteReady", let id = UUID(uuidString: hint.sessionId),
        hint.sessionId == id.uuidString.lowercased()
      else { throw Failure.invalidRouteHint }

      try policy.finishBootstrap()
      handedOff = true
      return Bootstrap(untrustedSessionIDHint: hint.sessionId, session: session, webSocketTask: task)
    } onCancel: {
      policy.cancel(session)
    }
  }

  private func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCredentialStorage = nil
    configuration.waitsForConnectivity = false
    var proxies = [kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesProxyAutoConfigEnable as String: 0]
    #if os(macOS)
    proxies[kCFNetworkProxiesHTTPSEnable as String] = 0
    proxies[kCFNetworkProxiesSOCKSEnable as String] = 0
    proxies[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] = 0
    #endif
    configuration.connectionProxyDictionary = proxies
    if let challengeProtocol = io.challengeProtocol { configuration.protocolClasses = [challengeProtocol] }
    return configuration
  }

  private static func bounded<T: Sendable>(
    _ duration: Duration, stage: Stage, cancel: () -> Void, operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: duration)
        throw Failure.transientUnavailable(stage)
      }
      defer { group.cancelAll() }
      do {
        guard let result = try await group.next() else { throw CancellationError() }
        return result
      } catch {
        // End the losing Foundation operation before the task group waits for its child.
        cancel()
        throw error
      }
    }
  }

  static func classify(
    _ error: any Error, stage: Stage, redirected: Bool, status: Int? = nil, closeCode: Int = 0
  ) -> Failure {
    if redirected { return .redirectRejected(stage) }
    if let status, status != 101 {
      switch status {
      case 403: return .admissionForbidden(stage)
      case 300..<400: return .redirectRejected(stage)
      default: return .unexpectedResponse(stage)
      }
    }
    if let failure = error as? Failure { return failure }
    if stage == .bootstrap {
      if closeCode == 4004 { return .transientUnavailable(stage) }
      if closeCode != 0, closeCode != 1006 { return .unexpectedResponse(stage) }
    }
    switch (error as? URLError)?.code {
    case .cannotConnectToHost, .notConnectedToInternet, .timedOut:
      return .transientUnavailable(stage)
    case .networkConnectionLost where stage == .challenge || status == 101:
      return .transientUnavailable(stage)
    default:
      // Foundation can hide an unsuccessful upgrade's HTTP status. Never retry an opaque denial.
      return .unexpectedResponse(stage)
    }
  }

  private struct RouteHint: Decodable {
    let kind: String
    let sessionId: String
  }

  final class SessionPolicy: NSObject, URLSessionDataDelegate {
    private struct PendingChallenge: Sendable {
      let taskID: Int
      let continuation: CheckedContinuation<Data, any Error>
      var body = Data()
    }

    private struct State: Sendable {
      var redirected = false
      var cancelled = false
      var pending: PendingChallenge?
      var webSocket: URLSessionWebSocketTask?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var redirected: Bool { state.withLock { $0.redirected } }

    fileprivate func readChallenge(_ request: URLRequest, on session: URLSession) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        let started = state.withLock { state in
          guard !state.cancelled else { return false }
          let task = session.dataTask(with: request)
          state.pending = PendingChallenge(taskID: task.taskIdentifier, continuation: continuation)
          task.resume()
          return true
        }
        if !started { continuation.resume(throwing: CancellationError()) }
      }
    }

    fileprivate func makeWebSocketTask(_ request: URLRequest, on session: URLSession) throws -> URLSessionWebSocketTask {
      try state.withLock { state in
        guard !state.cancelled else { throw CancellationError() }
        let task = session.webSocketTask(with: request)
        state.webSocket = task
        return task
      }
    }

    fileprivate func finishBootstrap() throws {
      try state.withLock { state in
        guard !state.cancelled else { throw CancellationError() }
        state.webSocket = nil
      }
    }

    fileprivate func cancel(_ session: URLSession) {
      let resources = state.withLock { state -> (PendingChallenge?, URLSessionWebSocketTask?)? in
        guard !state.cancelled else { return nil }
        state.cancelled = true
        defer {
          state.pending = nil
          state.webSocket = nil
        }
        return (state.pending, state.webSocket)
      }
      guard let (pending, task) = resources else { return }
      task?.cancel()
      session.invalidateAndCancel()
      pending?.continuation.resume(throwing: CancellationError())
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
      let failure: Failure?
      if let http = response as? HTTPURLResponse, http.url == dataTask.originalRequest?.url {
        switch http.statusCode {
        case 200:
          let maximum = Int64(ManagedRelayPhoneAdmission.maximumChallengeBytes)
          let contentLength = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
          failure = max(http.expectedContentLength, contentLength ?? -1) > maximum ? .invalidChallenge : nil
        case 403: failure = .admissionForbidden(.challenge)
        case 300..<400: failure = .redirectRejected(.challenge)
        default: failure = .unexpectedResponse(.challenge)
        }
      } else {
        failure = .unexpectedResponse(.challenge)
      }
      if let failure {
        finishChallenge(dataTask, error: failure)
        completionHandler(.cancel)
      } else {
        completionHandler(.allow)
      }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      let tooLarge = state.withLock { state -> PendingChallenge? in
        guard var pending = state.pending, pending.taskID == dataTask.taskIdentifier else { return nil }
        guard data.count <= ManagedRelayPhoneAdmission.maximumChallengeBytes - pending.body.count else {
          state.pending = nil
          return pending
        }
        pending.body.append(data)
        state.pending = pending
        return nil
      }
      if let tooLarge {
        dataTask.cancel()
        tooLarge.continuation.resume(throwing: Failure.invalidChallenge)
      }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
      finishChallenge(task, error: error)
    }

    private func finishChallenge(_ task: URLSessionTask, error: (any Error)?) {
      let pending = state.withLock { state -> PendingChallenge? in
        guard state.pending?.taskID == task.taskIdentifier else { return nil }
        defer { state.pending = nil }
        return state.pending
      }
      if let error { pending?.continuation.resume(throwing: error) }
      else if let pending { pending.continuation.resume(returning: pending.body) }
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      state.withLock { $0.redirected = true }
      completionHandler(nil)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
      completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}
#endif
