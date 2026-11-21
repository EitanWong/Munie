import Darwin
import Foundation
import MunieExecutionHost
import Testing

struct CodexHistoryProjectionTests {
  @Test func historyResultIncludesAssistantTextAndOmitsNativeCommandsPathsAndOtherFields()
    async throws
  {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let transport = HistoryTransport(
      directory: fixture.directory.path, home: fixture.directory.path, upstream: fixture.upstream,
      items: [
        .object([
          "type": .string("agentMessage"), "text": .string("First reply"),
          "privateField": .string("private"),
        ]),
        .object([
          "type": .string("commandExecution"), "aggregatedOutput": .string("private output"),
          "command": .string("private command"),
        ]),
        .object(["type": .string("agentMessage"), "text": .string("Second reply")]),
      ])
    let server = try CodexAppServer(
      transport: transport, workingDirectoryURL: fixture.directory, codexHomeURL: fixture.directory)
    try await server.initialize()
    #expect(try await server.read(fixture.upstream)?.status == .completed)
    #expect(try await server.readResult(fixture.upstream) == "First reply\n\nSecond reply")
    #expect(try await server.close().complete)
  }

  @Test func oversizedAndMalformedAssistantHistoryRejectsInsteadOfReturningRawPayload() async throws
  {
    for item in [
      CodexJSON.object([
        "type": .string("agentMessage"), "text": .string(String(repeating: "x", count: 262_145)),
      ]), .object(["type": .string("agentMessage"), "text": .integer(3)]),
    ] {
      let fixture = try HistoryFixture()
      defer { fixture.remove() }
      let transport = HistoryTransport(
        directory: fixture.directory.path, home: fixture.directory.path, upstream: fixture.upstream,
        items: [item])
      let server = try CodexAppServer(
        transport: transport, workingDirectoryURL: fixture.directory,
        codexHomeURL: fixture.directory)
      try await server.initialize()
      await #expect(throws: CodexClientError.self) { try await server.readResult(fixture.upstream) }
      #expect(try await server.close().complete)
    }
  }
}

private struct HistoryFixture {
  let directory: URL
  let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())
  init() throws {
    guard let pointer = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw CocoaError(.fileReadUnknown)
    }
    defer { free(pointer) }
    directory = URL(fileURLWithPath: String(cString: pointer), isDirectory: true).appending(
      path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor HistoryTransport: CodexRPCTransport {
  let directory: String
  let home: String
  let upstream: UpstreamTurn
  let items: [CodexJSON]
  var queue: [CodexJSON] = []
  var waiter: CheckedContinuation<CodexJSON, any Error>?
  var closed = false

  init(directory: String, home: String, upstream: UpstreamTurn, items: [CodexJSON]) {
    self.directory = directory
    self.home = home
    self.upstream = upstream
    self.items = items
  }

  func send(_ frame: CodexJSON) async throws {
    guard let object = frame.object, let id = object["id"], let method = object["method"]?.string
    else { return }
    let result: CodexJSON
    switch method {
    case "initialize":
      result = .object([
        "userAgent": .string("codex/0.162.1 fixture"), "platformFamily": .string("unix"),
        "platformOs": .string("macos"), "codexHome": .string(home),
      ])
    case "thread/read":
      result = .object([
        "thread": .object([
          "id": .string(upstream.threadID.uuidString.lowercased()), "cwd": .string(directory),
        ])
      ])
    case "thread/turns/list":
      result = .object([
        "data": .array([
          .object([
            "id": .string(upstream.turnID.uuidString.lowercased()), "status": .string("completed"),
            "items": .array(items),
          ])
        ]), "nextCursor": .null,
      ])
    default: throw CodexClientError.unsupportedMethod
    }
    let reply = CodexJSON.object(["id": id, "result": result])
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: reply)
    } else {
      queue.append(reply)
    }
  }

  func receive() async throws -> CodexJSON {
    if !queue.isEmpty { return queue.removeFirst() }
    if closed { throw CodexTransportError.closed }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }

  func shutdown() async throws -> CodexTransportCleanup {
    closed = true
    waiter?.resume(throwing: CodexTransportError.closed)
    waiter = nil
    return CodexTransportCleanup(
      leaderExitStatus: 0, stdoutEOF: true, stderrEOF: true, groupGone: true, escalated: false,
      stdinBytes: 0, stdoutBytes: 0, stderrBytes: 0)
  }
}
