import Darwin
import Foundation
import Testing

@testable import MunieExecutionHost

struct CodexStdioTransportTests {
  @Test func wireJSONPreservesTypesUnicodeAndRejectsAmbiguousInput() throws {
    let data = Data(
      #"{"n":null,"b":true,"i":9223372036854775807,"d":1.5,"s":"你好\u0000 👩🏽‍💻","a":[false,-1]}"#.utf8)
    let value = try CodexJSON.decode(data)
    #expect(value.object?["n"] == .null)
    #expect(value.object?["b"] == .bool(true))
    #expect(value.object?["i"] == .integer(Int64.max))
    #expect(value.object?["d"] == .number(1.5))
    #expect(value.object?["s"] == .string("你好\0 👩🏽‍💻"))
    #expect(try CodexJSON.decode(value.encoded()) == value)
    #expect(try CodexJSON.decode(Data("1.0".utf8)) == .number(1))
    #expect(try CodexJSON.decode(CodexJSON.number(1).encoded()) == .number(1))
    for text in [
      #"{"id":1,"id":2}"#, #"{"id":1,"\u0069d":2}"#, "01", "1.", "1e", "1e999",
      "9223372036854775808", "null true", #""\ud800""#,
    ] {
      #expect(throws: (any Error).self) { try CodexJSON.decode(Data(text.utf8)) }
    }
    #expect(throws: CodexJSONError.invalidUTF8) { try CodexJSON.decode(Data([255])) }
    #expect(throws: CodexJSONError.excessiveDepth) {
      try CodexJSON.decode(
        Data((String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)).utf8))
    }
    #expect(throws: (any Error).self) { try CodexJSON.number(.infinity).encoded() }
  }

  @Test func sendsExplicitEnvironmentAndHandlesFragmentedAndMultipleFrames() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var limits = fixture.limits
    // Allow CI scheduling and process reaping for normal EOF. The fault fixtures' 120ms grace
    // accelerates escalation tests; it is not a product shutdown latency requirement.
    limits.shutdownGrace = .seconds(3)
    let transport = try fixture.transport(
      """
      import json, os, signal, sys, time
      signal.signal(signal.SIGTERM, lambda *_: os._exit(71))
      for raw in sys.stdin.buffer:
          request = json.loads(raw)
          reply = json.dumps({"echo":request,"only":os.environ.get("MUNIE_SYNTHETIC"),"homePresent":"HOME" in os.environ,"cwd":os.getcwd()},ensure_ascii=False).encode()
          for part in [reply[:3],reply[3:10],reply[10:]]:
              os.write(1,part)
              time.sleep(0.005)
          os.write(1,b'\\n{"second":true}\\n')
          break
      os.write(1,b'{"awaitingEOF":true}\\n')
      sys.stdin.buffer.read()
      os.write(2,b'synthetic final stderr')
      os._exit(0)
      """, environment: ["MUNIE_SYNTHETIC": "explicit"], limits: limits)
    let frame = CodexJSON.object(["id": .integer(3), "text": .string("你好\0")])
    try await transport.send(frame)
    let first = try await transport.receive()
    #expect(first.object?["echo"] == frame)
    #expect(first.object?["only"] == .string("explicit"))
    #expect(first.object?["homePresent"] == .bool(false))
    #expect(first.object?["cwd"] == .string(fixture.directory.path))
    #expect(try await transport.receive() == .object(["second": .bool(true)]))
    #expect(try await transport.receive() == .object(["awaitingEOF": .bool(true)]))
    let result = try await transport.shutdown()
    #expect(result.complete)
    #expect(result.leaderExitStatus == 0)
    #expect(result.stderrBytes == "synthetic final stderr".utf8.count)
    #expect(!result.escalated)
    #expect(try await transport.shutdown() == result)
  }

  @Test func silenceTimesOutAndReapsOwnedGroup() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var limits = fixture.limits
    limits.readTimeout = .milliseconds(70)
    let transport = try fixture.transport("import time; time.sleep(60)", limits: limits)
    await #expect(throws: CodexTransportError.timeout) { try await transport.receive() }
    let result = try await transport.shutdown()
    #expect(result.complete)
    #expect(result.escalated)
    #expect(groupGone(transport.processGroupID))
  }

  @Test func invalidUTF8TruncatedAndBlankFramesFailClosed() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for bytes in ["b'\\xff\\n'", "b'{\"partial\":true}'", "b'\\n'", "b'{\"id\":1,\"id\":2}\\n'"] {
      let transport = try fixture.transport("import os; os.write(1,\(bytes))")
      await #expect(throws: CodexTransportError.invalidFrame) { try await transport.receive() }
      #expect(try await transport.shutdown().complete)
    }
  }

  @Test func nonzeroExitIsVisibleWithoutLeakingStderr() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let transport = try fixture.transport("import os; os.write(2,b'synthetic secret'); os._exit(7)")
    await #expect(throws: CodexTransportError.processExited(status: 7 << 8)) {
      try await transport.receive()
    }
    let result = try await transport.shutdown()
    #expect(result.complete)
    #expect(result.leaderExitStatus == 7 << 8)
    #expect(result.stderrBytes == 16)
    #expect(!String(describing: result).contains("synthetic secret"))
  }

  @Test func frameStdoutStderrAndQueueLimitsAreEnforced() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var limits = fixture.limits
    limits.maximumFrameBytes = 128
    limits.maximumStdoutBytes = 256
    limits.maximumStderrBytes = 128
    limits.maximumQueuedFrames = 2
    let cases: [(String, CodexTransportError)] = [
      ("import os; os.write(1,b'\"'+b'x'*200+b'\"\\n')", .frameTooLarge),
      ("import os; os.write(1,b'0\\n'*200)", .outputLimit),
      ("import os; os.write(2,b'x'*256)", .outputLimit),
      ("import os; os.write(1,b'0\\n'*3)", .queueLimit),
    ]
    for (script, expected) in cases {
      let transport = try fixture.transport(script, limits: limits)
      await #expect(throws: expected) { try await transport.receive() }
      #expect(try await transport.shutdown().complete)
    }
  }

  @Test func outputFloodIsBoundedAndChildIsKilled() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var limits = fixture.limits
    limits.maximumStderrBytes = 4096
    let transport = try fixture.transport(
      """
      import os, signal
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      while True: os.write(2,b'x'*4096)
      """, limits: limits)
    await #expect(throws: CodexTransportError.outputLimit) { try await transport.receive() }
    let result = try await transport.shutdown()
    #expect(result.complete)
    #expect(result.escalated)
  }

  @Test func finalStderrFloodIsRejectedAfterReaping() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var limits = fixture.limits
    limits.maximumStderrBytes = 128
    let transport = try fixture.transport(
      """
      import os, sys
      os.write(1,b'{"ready":true}\\n')
      sys.stdin.buffer.read()
      os.write(2,b'x'*512)
      """, limits: limits)
    #expect(try await transport.receive() == .object(["ready": .bool(true)]))
    await #expect(throws: CodexTransportError.outputLimit) { try await transport.shutdown() }
    #expect(groupGone(transport.processGroupID))
  }

  @Test func inputBackpressureTimesOutAndSendCancellationCleansUp() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var limits = fixture.limits
    limits.writeTimeout = .milliseconds(70)
    let slow = try fixture.transport("import time; time.sleep(60)", limits: limits)
    await #expect(throws: CodexTransportError.timeout) {
      try await slow.send(.string(String(repeating: "x", count: 500_000)))
    }
    #expect(try await slow.shutdown().complete)
    limits.writeTimeout = .seconds(3)
    let cancelled = try fixture.transport("import time; time.sleep(60)", limits: limits)
    let send = Task {
      try await cancelled.send(.string(String(repeating: "x", count: 500_000)))
    }
    try await Task.sleep(for: .milliseconds(30))
    send.cancel()
    await #expect(throws: CodexTransportError.cancelled) { try await send.value }
    #expect(try await cancelled.shutdown().complete)
  }

  @Test func receiveHasOneOwnerAndCancellationStillCleansUp() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let transport = try fixture.transport("import time; time.sleep(60)")
    let first = Task { try await transport.receive() }
    try await Task.sleep(for: .milliseconds(30))
    await #expect(throws: CodexTransportError.receiveInProgress) { try await transport.receive() }
    first.cancel()
    await #expect(throws: CodexTransportError.cancelled) { try await first.value }
    #expect(try await transport.shutdown().complete)
  }

  @Test func cancelledBeforeFirstReceiveStillCleansUp() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let transport = try fixture.transport("import time; time.sleep(60)")
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await transport.receive()
    }
    await #expect(throws: CodexTransportError.cancelled) { try await cancelled.value }
    #expect(try await transport.shutdown().complete)
  }

  @Test func shutdownFromCancelledTaskStillReapsLeaderAndDescendant() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let transport = try fixture.transport(
      """
      import os, signal, time
      child = os.fork()
      if child == 0:
          signal.signal(signal.SIGTERM, signal.SIG_IGN)
          while True: time.sleep(1)
      else:
          signal.signal(signal.SIGTERM, lambda *args: None)
          os.write(1,b'{"ready":true}\\n')
          os.waitpid(child,0)
      """)
    #expect(try await transport.receive() == .object(["ready": .bool(true)]))
    let task = Task { try await transport.shutdown() }
    task.cancel()
    let result = try await task.value
    #expect(result.complete)
    #expect(result.escalated)
    #expect(groupGone(transport.processGroupID))
  }

  @Test func orphanedDescendantCannotMakeLeaderExitLookLikeCleanup() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let transport = try fixture.transport(
      """
      import os, time
      if os.fork() == 0:
          while True: time.sleep(1)
      os.write(1,b'{"ready":true}\\n')
      os._exit(0)
      """)
    #expect(try await transport.receive() == .object(["ready": .bool(true)]))
    let result = try await transport.shutdown()
    #expect(result.complete)
    #expect(result.escalated)
    #expect(result.leaderExitStatus == 0)
    #expect(groupGone(transport.processGroupID))
  }

  @Test func sessionAndOutboundLimitsRejectAndCleanup() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var limits = fixture.limits
    limits.maximumFrameBytes = 16
    limits.maximumStdinBytes = 16
    let oversized = try fixture.transport("import sys; sys.stdin.buffer.read()", limits: limits)
    await #expect(throws: CodexTransportError.frameTooLarge) {
      try await oversized.send(.string(String(repeating: "x", count: 20)))
    }
    #expect(try await oversized.shutdown().complete)
    let total = try fixture.transport("import sys; sys.stdin.buffer.read()", limits: limits)
    try await total.send(.string("12345678"))
    await #expect(throws: CodexTransportError.inputLimit) {
      try await total.send(.string("12345678"))
    }
    #expect(try await total.shutdown().complete)
    limits.sessionTimeout = .milliseconds(30)
    let session = try fixture.transport("import time; time.sleep(60)", limits: limits)
    try await Task.sleep(for: .milliseconds(50))
    await #expect(throws: CodexTransportError.timeout) { try await session.receive() }
    #expect(try await session.shutdown().complete)
  }

  @Test func invalidLaunchParametersAndExecFailureExposeOnlyCodes() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(throws: CodexTransportError.invalidConfiguration) {
      try CodexStdioTransport(
        executableURL: URL(fileURLWithPath: "/missing-synthetic-executable"), arguments: [],
        environment: [:], workingDirectoryURL: fixture.directory)
    }
    #expect(throws: CodexTransportError.invalidConfiguration) {
      try fixture.transport("pass", environment: ["BAD=KEY": "value"])
    }
    let executable = fixture.directory.appendingPathComponent("invalid-executable")
    try Data("synthetic invalid executable".utf8).write(to: executable)
    #expect(chmod(executable.path, 0o700) == 0)
    #expect(throws: CodexTransportError.launchFailed(code: ENOEXEC)) {
      try CodexStdioTransport(
        executableURL: executable, arguments: [], environment: [:],
        workingDirectoryURL: fixture.directory)
    }
  }

  private struct Fixture {
    let directory: URL
    var limits: CodexTransportLimits {
      var limits = CodexTransportLimits()
      limits.readTimeout = .seconds(3)
      limits.writeTimeout = .seconds(3)
      limits.sessionTimeout = .seconds(10)
      // Failure/descendant tests intentionally exercise bounded TERM/KILL escalation quickly.
      limits.shutdownGrace = .milliseconds(120)
      return limits
    }

    init() throws {
      let root = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
      defer { free(root) }
      directory = URL(fileURLWithPath: String(cString: root), isDirectory: true)
        .appendingPathComponent("MunieTransportTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func transport(
      _ script: String, environment: [String: String] = [:], limits: CodexTransportLimits? = nil
    ) throws -> CodexStdioTransport {
      try CodexStdioTransport(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", "-c", script],
        environment: environment, workingDirectoryURL: directory, limits: limits ?? self.limits)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
  }

  private func groupGone(_ process: Int32) -> Bool {
    kill(-process, 0) != 0 && errno == ESRCH
  }
}
