import Foundation
import MunieProductHost
import MunieRemote
import Network

/// A bounded, loopback-only HTTP hop for a same-Mac HTTPS terminator (Tailscale Serve).
/// There is no unencrypted LAN listener, browser API, forwarded-identity trust, or arbitrary RPC.
public actor HostHTTPServer {
  private let host: ProductHost
  private let listener: NWListener
  private let queue = DispatchQueue(label: "app.munie.host.http")
  private var connections: [UUID: NWConnection] = [:]
  private var handlers: [UUID: Task<Void, Never>] = [:]
  private var stopped = false
  private var started = false

  public init(host: ProductHost, port: UInt16 = 9274) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: .ipv4(.loopback), port: .init(rawValue: port)!)
    parameters.allowLocalEndpointReuse = false
    listener = try NWListener(using: parameters)
    self.host = host
  }

  public func start() async throws -> UInt16 {
    guard !stopped, !started else { throw HostHTTPError.closed }
    started = true
    listener.newConnectionHandler = { [weak self] connection in
      Task { await self?.accept(connection) }
    }
    return try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready:
          listener.stateUpdateHandler = nil
          if let port = listener.port {
            continuation.resume(returning: port.rawValue)
          } else {
            continuation.resume(throwing: HostHTTPError.closed)
          }
        case .failed(let error):
          listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        case .cancelled:
          listener.stateUpdateHandler = nil
          continuation.resume(throwing: HostHTTPError.closed)
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  public func stop() {
    stopped = true
    listener.cancel()
    for connection in connections.values { connection.cancel() }
    for handler in handlers.values { handler.cancel() }
    connections.removeAll()
    handlers.removeAll()
  }

  private func accept(_ connection: NWConnection) {
    guard !stopped, connections.count < 16 else {
      connection.cancel()
      return
    }
    let id = UUID()
    connections[id] = connection
    connection.start(queue: queue)
    handlers[id] = Task { [weak self] in await self?.serve(connection, id: id) }
  }

  private func serve(_ connection: NWConnection, id: UUID) async {
    let deadline = Task {
      do {
        try await Task.sleep(for: .seconds(30))
        connection.cancel()
      } catch { return }
    }
    defer {
      deadline.cancel()
      connection.cancel()
      connections[id] = nil
      handlers[id] = nil
    }
    do {
      var bytes = Data()
      var request: HostHTTPRequest?
      while request == nil {
        let chunk = try await Self.receive(connection)
        guard !chunk.isEmpty else { throw HostHTTPError.invalidRequest }
        bytes.append(chunk)
        request = try HostHTTPRequest.decode(bytes)
      }
      guard let request else { throw HostHTTPError.invalidRequest }
      let decoder = JSONDecoder()
      let operation = try decoder.decode(RemoteRequest.self, from: request.body)
      let result = await host.handle(operation, credential: request.credential)
      let body = try JSONEncoder().encode(result)
      guard body.count <= 2_097_152 else { throw HostHTTPError.responseLimit }
      try await Self.send(connection, status: "200 OK", body: body)
    } catch {
      // No raw error, credentials, request, native payload, or HTTP headers enter diagnostics.
      do { try await Self.send(connection, status: "400 Bad Request", body: Data("{}".utf8)) } catch
      { return }
    }
  }

  private static func receive(_ connection: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
        data, _, complete, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if complete {
          continuation.resume(returning: Data())
        } else {
          continuation.resume(throwing: HostHTTPError.closed)
        }
      }
    }
  }

  private static func send(_ connection: NWConnection, status: String, body: Data) async throws {
    var response = Data(
      "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        .utf8)
    response.append(body)
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: response,
        completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
  }
}

public enum HostHTTPError: Error { case invalidRequest, responseLimit, closed }

/// Deliberately one request per connection. Reject ambiguity instead of supporting HTTP extensions.
struct HostHTTPRequest: Equatable {
  let credential: String?
  let body: Data

  static func decode(_ data: Data) throws -> Self? {
    guard data.count <= 73_728 else { throw HostHTTPError.invalidRequest }
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
      guard data.count <= 8192 else { throw HostHTTPError.invalidRequest }
      return nil
    }
    guard separator.lowerBound <= 8192,
      let header = String(data: data[..<separator.lowerBound], encoding: .ascii)
    else { throw HostHTTPError.invalidRequest }
    let lines = header.components(separatedBy: "\r\n")
    guard lines.first == "POST /v1 HTTP/1.1" else { throw HostHTTPError.invalidRequest }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
        throw HostHTTPError.invalidRequest
      }
      let name = String(line[..<colon]).lowercased()
      guard name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }), headers[name] == nil
      else {
        throw HostHTTPError.invalidRequest
      }
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
        throw HostHTTPError.invalidRequest
      }
      headers[name] = value
    }
    guard let length = headers["content-length"], !length.isEmpty,
      length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length),
      count > 0, count <= 65_536, headers["transfer-encoding"] == nil,
      headers["expect"] == nil, headers["origin"] == nil,
      headers["content-type"]?.lowercased() == "application/json",
      let hostname = headers["host"], !hostname.isEmpty
    else { throw HostHTTPError.invalidRequest }
    let available = data.count - separator.upperBound
    guard available <= count else { throw HostHTTPError.invalidRequest }
    guard available == count else { return nil }
    var credential: String?
    if let authorization = headers["authorization"] {
      guard authorization.hasPrefix("Bearer "), authorization.utf8.count <= 520 else {
        throw HostHTTPError.invalidRequest
      }
      credential = String(authorization.dropFirst(7))
    }
    return Self(credential: credential, body: Data(data[separator.upperBound...]))
  }
}
