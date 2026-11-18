import Darwin
import Foundation

/// A dead controller cannot answer stop. This read-only helper checks the exact locally recorded
/// owner/group pair; it never starts Codex, reads account state or signals a worker group.
enum DesktopCleanupVerifier {
  private struct Response: Decodable {
    let v: Int
    let method: String
    let ownership: DesktopProcessOwnership
    let cleanupConfirmed: Bool
    let error: DesktopHostControlError?
  }

  static func verify(
    _ ownership: DesktopProcessOwnership, configuration: DesktopRuntimeConfiguration
  ) async -> Bool {
    let verifier = Process()
    let output = Pipe()
    verifier.executableURL = configuration.node
    verifier.arguments = [
      configuration.entryPoint.path, "--verify-cleanup", String(ownership.ownerPid),
      String(ownership.groupId),
    ]
    verifier.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    verifier.standardInput = FileHandle.nullDevice
    verifier.standardOutput = output
    verifier.standardError = FileHandle.nullDevice
    let handle = output.fileHandleForReading
    defer {
      do { try handle.close() } catch {
        // This verifier owns no work and the result remains conservative on any close failure.
      }
    }
    do {
      let flags = fcntl(handle.fileDescriptor, F_GETFL)
      guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        return false
      }
      try verifier.run()
      try output.fileHandleForWriting.close()
    } catch { return false }
    let deadline = ContinuousClock.now.advanced(by: .seconds(12))
    var bytes = Data()
    var readingFailed = false
    while ContinuousClock.now < deadline {
      var chunk = [UInt8](repeating: 0, count: 4096)
      let count = chunk.withUnsafeMutableBytes { buffer in
        Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
      }
      if count > 0 {
        bytes.append(contentsOf: chunk.prefix(count))
        if bytes.count > 32_768 {
          readingFailed = true
          break
        }
      } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
        readingFailed = true
        break
      } else if count == 0, !verifier.isRunning {
        break
      }
      do { try await Task.sleep(for: .milliseconds(20)) } catch {
        readingFailed = true
        break
      }
    }
    if verifier.isRunning {
      // This is only the dedicated read-only verifier we just launched, never the owned group.
      verifier.terminate()
      let exitDeadline = ContinuousClock.now.advanced(by: .seconds(1))
      while verifier.isRunning, ContinuousClock.now < exitDeadline {
        do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
      }
      if verifier.isRunning { _ = Darwin.kill(verifier.processIdentifier, SIGKILL) }
      return false
    }
    guard !readingFailed, verifier.terminationStatus == 0,
      let response = try? JSONDecoder().decode(Response.self, from: bytes), response.v == 1,
      response.method == "verify-cleanup", response.ownership == ownership,
      response.cleanupConfirmed, response.error == nil
    else { return false }
    return true
  }
}
