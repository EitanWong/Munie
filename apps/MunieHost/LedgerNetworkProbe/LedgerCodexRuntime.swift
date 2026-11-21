import Darwin
import Foundation
import MunieExecutionHost

/// Owns every native resource even when initialization fails before the ready frame.
struct LedgerCodexRuntime {
  let configuration: LedgerNetworkConfiguration
  let codex: URL
  let python: URL
  let guardian: URL
  let scenario: LedgerCodexScenario
  var transport: CodexStdioTransport?
  var client: CodexAppServer?
  var session: HostCodexSession?

  init(configuration: LedgerNetworkConfiguration, arguments: [String]) throws {
    guard arguments.count == 4, let scenario = LedgerCodexScenario(rawValue: arguments[3]) else {
      throw LedgerCodexFailure.invalidConfiguration
    }
    let urls = arguments.prefix(3).map { URL(fileURLWithPath: $0) }
    for (raw, url) in zip(arguments.prefix(3), urls) {
      guard raw.hasPrefix("/"), raw == url.path, !raw.utf8.contains(0), raw.utf8.count <= 4096,
        FileManager.default.isReadableFile(atPath: raw)
      else { throw LedgerCodexFailure.invalidConfiguration }
    }
    guard FileManager.default.isExecutableFile(atPath: urls[0].path),
      FileManager.default.isExecutableFile(atPath: urls[1].path)
    else { throw LedgerCodexFailure.invalidConfiguration }
    self.configuration = configuration
    self.codex = urls[0]
    self.python = urls[1]
    self.guardian = urls[2]
    self.scenario = scenario
  }

  mutating func run() async throws -> CodexTransportCleanup {
    let root = configuration.root
    let home = root.appendingPathComponent("codex-data", isDirectory: true)
    let temporary = root.appendingPathComponent("tmp", isDirectory: true)
    let sandbox = root.appendingPathComponent("sandbox.sb")
    for directory in [home, temporary] {
      try LedgerNetworkConfiguration.validatePrivateDirectory(directory)
    }
    try LedgerNetworkConfiguration.validatePrivateFile(
      home.appendingPathComponent("config.toml"), minimumBytes: 1, maximumBytes: 16_384)
    try LedgerNetworkConfiguration.validatePrivateFile(
      sandbox, minimumBytes: 1, maximumBytes: 32_768)
    let bridge = try await LedgerNetworkBridge.open(configuration)
    guard let project = configuration.projects.first else {
      throw LedgerCodexFailure.invalidConfiguration
    }
    let workspace = configuration.projectDirectory(project)
    var limits = CodexTransportLimits()
    limits.readTimeout = .seconds(20)
    limits.sessionTimeout = .seconds(60)
    let native = try CodexStdioTransport(
      executableURL: python,
      arguments: [
        "-I", guardian.path, "--parent-pid", String(getpid()),
        "--registry", root.appendingPathComponent("native-codex.json").path,
        "--", "/usr/bin/sandbox-exec", "-f", sandbox.path, codex.path, "app-server", "--stdio",
      ],
      environment: [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "CODEX_HOME": home.path,
        "TMPDIR": temporary.path, "LANG": "en_US.UTF-8",
      ], workingDirectoryURL: workspace, limits: limits)
    transport = native
    let client = try CodexAppServer(
      transport: native, workingDirectoryURL: workspace, codexHomeURL: home)
    self.client = client
    try await client.initialize()
    let session = try HostCodexSession(ledger: bridge.ledger, adapter: client)
    self.session = session
    let facade = try LedgerCodexBridge(
      bridge: bridge, session: session, configuration: configuration, scenario: scenario)
    try LedgerNetworkWire.emit(
      .object([
        "event": .string("ready"), "sqliteVersion": .string(await bridge.ledger.sqliteVersion),
        "nativeGroup": .integer(Int64(native.processGroupID)),
      ]))
    while let line = try LedgerNetworkWire.readLine(from: .standardInput) {
      try LedgerNetworkWire.emit(try await facade.respond(to: line))
    }
    let cleanup = try await session.close()
    guard cleanup.complete, cleanup.withinLimits else { throw LedgerCodexFailure.cleanupIncomplete }
    return cleanup
  }

  func cleanupAfterFailure() async -> (CodexJSON, CodexJSON) {
    do {
      let cleanup: CodexTransportCleanup
      if let session {
        cleanup = try await session.close()
      } else if let client {
        cleanup = try await client.close()
      } else if let transport {
        cleanup = try await transport.shutdown()
      } else {
        return (.null, .null)
      }
      return (Self.cleanupJSON(cleanup), .null)
    } catch let failure as HostCodexCloseFailure {
      return (failure.cleanup.map(Self.cleanupJSON) ?? .null, .string("close-failure"))
    } catch {
      // A failed client close may still leave transport cleanup evidence available.
      if let transport, let cleanup = try? await transport.shutdown() {
        return (Self.cleanupJSON(cleanup), .string(Self.safeCode(error)))
      }
      return (.null, .string(Self.safeCode(error)))
    }
  }

  static func cleanupJSON(_ cleanup: CodexTransportCleanup) -> CodexJSON {
    .object([
      "leaderExitStatus": cleanup.leaderExitStatus.map { .integer(Int64($0)) } ?? .null,
      "stdoutEOF": .bool(cleanup.stdoutEOF), "stderrEOF": .bool(cleanup.stderrEOF),
      "groupGone": .bool(cleanup.groupGone), "escalated": .bool(cleanup.escalated),
      "stdinBytes": .integer(Int64(cleanup.stdinBytes)),
      "stdoutBytes": .integer(Int64(cleanup.stdoutBytes)),
      "stderrBytes": .integer(Int64(cleanup.stderrBytes)),
    ])
  }

  static func safeCode(_ error: any Error) -> String {
    switch error {
    case is LedgerCodexFailure: "fixture-failure"
    case is LedgerNetworkProbeFailure: "input-failure"
    case let value as CodexClientError:
      switch value {
      case .rpc(let code): "client-rpc-\(code)"
      case .permissionMismatch: "client-permission-mismatch"
      case .identityMismatch: "client-identity-mismatch"
      case .responseMismatch: "client-response-mismatch"
      case .invalidTransition: "client-invalid-transition"
      case .transportFailure: "client-transport-failure"
      case .malformedFrame: "client-malformed-frame"
      case .closed: "client-closed"
      case .notInitialized: "client-not-initialized"
      case .busy: "client-busy"
      case .eventLimit: "client-event-limit"
      case .transport: "client-transport"
      case .unsupportedVersion: "client-unsupported-version"
      case .unsupportedMethod: "client-unsupported-method"
      case .alreadyInitialized: "client-already-initialized"
      case .invalidConfiguration: "client-invalid-configuration"
      case .staleApproval: "client-stale-approval"
      case .unavailableDecision: "client-unavailable-decision"
      case .paginationLimit: "client-pagination-limit"
      }
    case is CodexTransportError: "transport-failure"
    case is SubmissionError: "ledger-failure"
    case is HostCodexSessionError: "session-failure"
    case is HostCodexCloseFailure: "close-failure"
    case is HostCodexRecoveryFailure: "recovery-failure"
    case is CancellationError: "cancelled"
    default: "unexpected-failure"
    }
  }
}
