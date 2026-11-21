#if DEBUG
  import Foundation
  import Network
  import Testing

  @testable import MunieRemote

  struct HTTPTransportTests {
    @Test func actualLoopbackResponseIsDecodedAndBearerStaysInHeader() async throws {
      let payload = try JSONEncoder().encode(RemoteResponse(pairingState: .pending))
      let peer = try HTTPTestPeer(response: response(body: payload))
      let endpoint = try await peer.start()
      let token = String(repeating: "a", count: 64)
      let client = try RemoteHTTPClient(loopbackEndpoint: endpoint, credential: token)
      do {
        let result = try await client.call(RemoteRequest(op: .status))
        #expect(result.pairingState == .pending)
        let headers = await peer.headers
        #expect(headers?.contains("Authorization: Bearer \(token)") == true)
        #expect(headers?.hasPrefix("POST /v1 HTTP/1.1") == true)
        await peer.stop()
      } catch {
        await peer.stop()
        throw error
      }
    }

    @Test func redirectNeverContactsCredentialDestination() async throws {
      let destination = try HTTPTestPeer(response: response(body: Data("{}".utf8)))
      let target = try await destination.start()
      let redirect = Data(
        "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(target.absoluteString)/v1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          .utf8)
      let origin = try HTTPTestPeer(response: redirect)
      let endpoint = try await origin.start()
      let client = try RemoteHTTPClient(
        loopbackEndpoint: endpoint, credential: String(repeating: "a", count: 64))
      await #expect(throws: RemoteClientError.invalidResponse) {
        try await client.call(RemoteRequest(op: .status))
      }
      #expect(await destination.headers == nil)
      await origin.stop()
      await destination.stop()
    }

    @Test func declaredAndUndeclaredOversizeBodiesFail() async throws {
      let size = RemoteHTTPClient.maximumResponseBytes + 1
      for includeLength in [true, false] {
        let body = Data(repeating: 32, count: size)
        let peer = try HTTPTestPeer(response: response(body: body, includeLength: includeLength))
        let endpoint = try await peer.start()
        let client = try RemoteHTTPClient(loopbackEndpoint: endpoint)
        await #expect(throws: RemoteClientError.responseTooLarge) {
          try await client.call(RemoteRequest(op: .status))
        }
        await peer.stop()
      }
    }

    @Test func inFlightCancellationStopsWaitingForResponse() async throws {
      let peer = try HTTPTestPeer(response: nil)
      let endpoint = try await peer.start()
      let client = try RemoteHTTPClient(loopbackEndpoint: endpoint)
      let operation = Task { try await client.call(RemoteRequest(op: .status)) }
      await peer.waitForRequest()
      operation.cancel()
      await #expect(throws: RemoteClientError.cancelled) { try await operation.value }
      await peer.stop()
    }

    private func response(body: Data, includeLength: Bool = true) -> Data {
      let length = includeLength ? "Content-Length: \(body.count)\r\n" : ""
      var result = Data(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\(length)Connection: close\r\n\r\n"
          .utf8
      )
      result.append(body)
      return result
    }
  }

  private actor HTTPTestPeer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MunieRemote.HTTPTestPeer")
    private let response: Data?
    private var connections: [NWConnection] = []
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private(set) var headers: String?

    init(response: Data?) throws {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      listener = try NWListener(using: parameters)
      self.response = response
    }

    func start() async throws -> URL {
      let listener = self.listener
      listener.newConnectionHandler = { connection in
        Task { await self.respond(to: connection) }
      }
      let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { state in
          switch state {
          case .ready:
            listener.stateUpdateHandler = nil
            if let port = listener.port {
              continuation.resume(returning: port)
            } else {
              continuation.resume(throwing: RemoteClientError.disconnected)
            }
          case .failed(let error):
            listener.stateUpdateHandler = nil
            continuation.resume(throwing: error)
          default: break
          }
        }
        listener.start(queue: queue)
      }
      return URL(string: "http://127.0.0.1:\(port.rawValue)")!
    }

    func waitForRequest() async {
      if headers != nil { return }
      await withCheckedContinuation { requestWaiter = $0 }
    }

    func stop() {
      listener.cancel()
      for connection in connections { connection.cancel() }
      requestWaiter?.resume()
      requestWaiter = nil
    }

    private func respond(to connection: NWConnection) async {
      connections.append(connection)
      connection.start(queue: queue)
      do {
        var received = Data()
        while received.count <= 16_384 {
          let chunk: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
              data, _, complete, error in
              if let error {
                continuation.resume(throwing: error)
              } else if let data, !data.isEmpty {
                continuation.resume(returning: data)
              } else {
                continuation.resume(throwing: RemoteClientError.disconnected)
              }
            }
          }
          received.append(chunk)
          if let marker = received.range(of: Data("\r\n\r\n".utf8)) {
            headers = String(data: received[..<marker.lowerBound], encoding: .utf8)
            requestWaiter?.resume()
            requestWaiter = nil
            if let response {
              try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(
                  content: response,
                  contentContext: .finalMessage,
                  isComplete: true,
                  completion: .contentProcessed { error in
                    if let error {
                      continuation.resume(throwing: error)
                    } else {
                      continuation.resume()
                    }
                  })
              }
              // The stack processing the bytes is not the peer receiving them.
              // Send a TCP FIN after the response; stop() owns connection cleanup.
            }
            return
          }
        }
        connection.cancel()
      } catch {
        connection.cancel()
      }
    }
  }

#endif
