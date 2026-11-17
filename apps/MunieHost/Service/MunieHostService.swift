import Foundation
import MunieHostTransport
import MunieProductHost
import MunieRemote

/// Local development/diagnostic entry; the shipping Mac app owns the same runtime directly.
/// Administrative operations exist only on the inherited local pipe, never on HTTP.
@main
struct MunieHostService {
  struct Configuration: Codable {
    struct Project: Codable {
      let id: UUID
      let name: String
      let directory: URL
    }
    let hostID: UUID
    let stateDirectory: URL
    let codexHome: URL
    let executable: URL
    let guardian: URL
    let projects: [Project]
    let endpoint: URL
    let port: UInt16
  }
  struct Command: Decodable {
    let op: String
    let projectIDs: [UUID]?
    let deviceID: UUID?
  }
  struct Reply: Encodable {
    var event: String
    var port: UInt16?
    var invitation: PairingInvitation?
    var candidate: Candidate?
    var status: RemoteStatus?
    var diagnostics: Diagnostics?
    struct Candidate: Encodable {
      let id: UUID
      let name: String
      let fingerprint: String
    }
    struct Diagnostics: Encodable {
      let failure: String?
      let groupGone: Bool?
      let stdoutEOF: Bool?
      let stderrEOF: Bool?
      let leaderExitStatus: Int32?
      let escalated: Bool?
    }
  }

  static func main() async {
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--configuration" else {
      FileHandle.standardError.write(
        Data("Usage: MunieHostService --configuration ABSOLUTE_JSON_PATH\n".utf8))
      Foundation.exit(64)
    }
    do {
      let config = try JSONDecoder().decode(
        Configuration.self,
        from: Data(contentsOf: URL(filePath: CommandLine.arguments[2])))
      let runtime = NativeCodexRuntime(
        executable: config.executable, guardian: config.guardian,
        codexHome: config.codexHome, hostState: config.stateDirectory)
      try runtime.prepare(
        usingLocalLoginAt: FileManager.default.homeDirectoryForCurrentUser
          .appending(path: ".codex/auth.json"))
      let probe = try await runtime.adapter(for: config.codexHome)
      _ = try await probe.close()
      let push = try HostPushNotifications(
        configuration: HostPushNotifications.loadConfiguration(in: config.stateDirectory))
      let host = try ProductHost(
        directoryURL: config.stateDirectory, hostID: config.hostID,
        hostName: "Munie Mac", codexReady: true,
        adapterFactory: { directory in try await runtime.adapter(for: directory) },
        notificationSink: { device, task in await push.send(deviceID: device, task: task) })
      await push.bind(host)
      for project in config.projects {
        try await host.registerProject(
          id: project.id, name: project.name, directoryURL: project.directory)
      }
      let server = try HostHTTPServer(host: host, port: config.port)
      let port = try await server.start()
      try output(Reply(event: "ready", port: port))
      // This blocking pipe read runs on a dedicated task, never the UI actor or network executor.
      let input = AsyncStream<String> { continuation in
        Thread.detachNewThread {
          while let line = readLine() { continuation.yield(line) }
          continuation.finish()
        }
      }
      for await line in input {
        do {
          let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
          switch command.op {
          case "invite":
            let invitation = try await host.startPairing(endpoint: config.endpoint)
            try output(Reply(event: "invitation", invitation: invitation))
          case "candidate":
            let pending = await host.pendingPairing()
            try output(
              Reply(
                event: "candidate",
                candidate: pending.map {
                  .init(id: $0.id, name: $0.name, fingerprint: $0.fingerprint)
                }))
          case "approvePairing":
            guard let ids = command.projectIDs else { throw HostHTTPError.invalidRequest }
            try await host.approvePairing(projectIDs: Set(ids))
            try output(Reply(event: "paired"))
          case "revoke":
            guard let id = command.deviceID else { throw HostHTTPError.invalidRequest }
            try await host.revokeDevice(id: id)
            try output(Reply(event: "revoked"))
          case "status": try output(Reply(event: "status", status: await host.localStatus()))
          case "diagnostics":
            let cleanup = await host.lastCleanup
            try output(
              Reply(
                event: "diagnostics",
                diagnostics: .init(
                  failure: await host.lastExecutionFailure, groupGone: cleanup?.groupGone,
                  stdoutEOF: cleanup?.stdoutEOF, stderrEOF: cleanup?.stderrEOF,
                  leaderExitStatus: cleanup?.leaderExitStatus, escalated: cleanup?.escalated)))
          case "quit":
            await server.stop()
            try await host.close()
            await push.close()
            try output(Reply(event: "closed"))
            return
          default: throw HostHTTPError.invalidRequest
          }
        } catch { try output(Reply(event: "operationFailed")) }
      }
      await server.stop()
      try await host.close()
      await push.close()
    } catch {
      FileHandle.standardError.write(Data("Munie host could not start or close cleanly.\n".utf8))
      Foundation.exit(1)
    }
  }

  static func output(_ reply: Reply) throws {
    var bytes = try JSONEncoder().encode(reply)
    bytes.append(10)
    FileHandle.standardOutput.write(bytes)
  }
}
