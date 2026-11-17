import Darwin
import Foundation
import MunieExecutionHost

enum LedgerNetworkWire {
  static func readLine(from input: FileHandle) throws -> Data? {
    var data = Data()
    while let byte = try input.read(upToCount: 1), !byte.isEmpty {
      if byte.first == 10 { return data }
      guard data.count < 4096 else { throw LedgerNetworkProbeFailure.framing }
      data.append(byte)
    }
    guard data.isEmpty else { throw LedgerNetworkProbeFailure.framing }
    return nil
  }

  static func emit(_ value: CodexJSON, to output: FileHandle = .standardOutput) throws {
    var data = try value.encoded(maximumBytes: 2047)
    data.append(10)
    guard data.count <= 2048 else { throw LedgerNetworkProbeFailure.responseLimit }
    try output.write(contentsOf: data)
  }
}

@main
struct MunieLedgerNetworkProbe {
  static func main() async {
    do {
      guard CommandLine.arguments.count == 2 else {
        throw LedgerNetworkProbeFailure.invalidConfiguration
      }
      let configuration = try LedgerNetworkConfiguration.load(path: CommandLine.arguments[1])
      try await run(configuration)
      try LedgerNetworkWire.emit(.object(["event": .string("closed")]))
    } catch {
      // No raw errors, storage paths, identities, certificate data or request text in diagnostics.
      try? FileHandle.standardError.write(contentsOf: Data("Ledger network probe failed\n".utf8))
      exit(1)
    }
  }

  private static func run(_ configuration: LedgerNetworkConfiguration) async throws {
    let bridge = try await LedgerNetworkBridge.open(configuration)
    try LedgerNetworkWire.emit(
      .object([
        "event": .string("ready"), "sqliteVersion": .string(await bridge.ledger.sqliteVersion),
      ]))
    while let line = try LedgerNetworkWire.readLine(from: .standardInput) {
      try LedgerNetworkWire.emit(try await bridge.respond(to: line))
    }
  }
}
