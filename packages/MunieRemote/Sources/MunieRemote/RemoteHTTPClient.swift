import Foundation

public enum RemoteClientError: Error, Equatable, Sendable {
  case invalidEndpoint, invalidCredential, invalidInput, invalidResponse, responseTooLarge
  case disconnected, cancelled, unauthorized, persistence, unconfigured, busy
  case remote(RemoteErrorCode)
}

/// A bounded HTTPS request client. Credentials never enter a URL or a redirected request.
public actor RemoteHTTPClient: RemoteClient {
  public static let maximumResponseBytes = 2_097_152
  private let endpoint: URL
  private let credential: String?
  private let session: URLSession

  public init(endpoint: URL, credential: String? = nil) throws {
    try self.init(endpoint: endpoint, credential: credential, allowsLoopbackHTTP: false)
  }

  #if DEBUG
    /// Explicit opt-in only for isolated automated tests on this same computer.
    public init(loopbackEndpoint: URL, credential: String? = nil) throws {
      try self.init(endpoint: loopbackEndpoint, credential: credential, allowsLoopbackHTTP: true)
    }
  #endif

  private init(endpoint: URL, credential: String?, allowsLoopbackHTTP: Bool) throws {
    self.endpoint = try Self.validatedEndpoint(endpoint, allowsLoopbackHTTP: allowsLoopbackHTTP)
    if let credential {
      guard (32...512).contains(credential.utf8.count),
        credential.utf8.allSatisfy({ (33...126).contains($0) })
      else { throw RemoteClientError.invalidCredential }
    }
    self.credential = credential
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.waitsForConnectivity = false
    configuration.connectionProxyDictionary = [:]
    self.session = URLSession(
      configuration: configuration, delegate: RemoteSessionDelegate(), delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }

  public func call(_ request: RemoteRequest) async throws -> RemoteResponse {
    let encoder = JSONEncoder()
    let body = try encoder.encode(request)
    guard body.count <= 65_536 else { throw RemoteClientError.invalidInput }
    var native = URLRequest(url: endpoint)
    native.httpMethod = "POST"
    native.setValue("application/json", forHTTPHeaderField: "Content-Type")
    native.setValue("application/json", forHTTPHeaderField: "Accept")
    native.httpBody = body
    if let credential {
      native.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    }
    do {
      let (bytes, response) = try await session.bytes(for: native)
      defer { bytes.task.cancel() }
      guard let http = response as? HTTPURLResponse, http.url == endpoint else {
        throw RemoteClientError.invalidResponse
      }
      if http.statusCode == 401 || http.statusCode == 403 { throw RemoteClientError.unauthorized }
      guard http.statusCode == 200,
        http.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first?
          .trimmingCharacters(in: .whitespaces) == "application/json"
      else { throw RemoteClientError.invalidResponse }
      guard http.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
        throw RemoteClientError.responseTooLarge
      }
      let nativeTask = bytes.task
      let data = try await withTaskCancellationHandler {
        var data = Data()
        for try await byte in bytes {
          try Task.checkCancellation()
          guard data.count < Self.maximumResponseBytes else {
            throw RemoteClientError.responseTooLarge
          }
          data.append(byte)
        }
        return data
      } onCancel: {
        nativeTask.cancel()
      }
      let decoded: RemoteResponse
      do { decoded = try JSONDecoder().decode(RemoteResponse.self, from: data) } catch {
        throw RemoteClientError.invalidResponse
      }
      if let error = decoded.error { throw RemoteClientError.remote(error) }
      return decoded
    } catch let error as RemoteClientError {
      throw error
    } catch is CancellationError {
      throw RemoteClientError.cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw RemoteClientError.cancelled
    } catch {
      throw RemoteClientError.disconnected
    }
  }

  static func validatedEndpoint(_ endpoint: URL, allowsLoopbackHTTP: Bool = false) throws -> URL {
    guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil,
      ["", "/", "/v1"].contains(parts.percentEncodedPath),
      parts.port == nil || (1...65_535).contains(parts.port!)
    else { throw RemoteClientError.invalidEndpoint }
    let isLoopback = ["127.0.0.1", "[::1]", "::1"].contains(host)
    guard
      parts.scheme?.lowercased() == "https"
        || (allowsLoopbackHTTP && parts.scheme?.lowercased() == "http" && isLoopback)
    else { throw RemoteClientError.invalidEndpoint }
    parts.path = "/v1"
    guard let result = parts.url else { throw RemoteClientError.invalidEndpoint }
    return result
  }
}

private final class RemoteSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
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
