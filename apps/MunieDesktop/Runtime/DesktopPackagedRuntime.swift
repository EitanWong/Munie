import Darwin
import Foundation

struct DesktopRuntimeConfiguration: Sendable {
  let node: URL
  let entryPoint: URL
  let codex: URL
  let stateDirectory: URL
  let defaultProject: URL

  static func bundled(in bundle: Bundle = .main) async throws -> Self {
    guard let resources = bundle.resourceURL else {
      throw DesktopHostFailure.resourcesUnavailable
    }
    return try await Task.detached {
      let files = FileManager.default
      let support = try files.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
      let root = support.appending(path: "Munie", directoryHint: .isDirectory)
      let state = root.appending(path: "Desktop", directoryHint: .isDirectory)
      let project = root.appending(path: "Projects/My Project", directoryHint: .isDirectory)
      for directory in [root, state, project] {
        try files.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
      let configuration = Self(
        node: resources.appending(path: "Runtime/bin/node"),
        entryPoint: resources.appending(path: "Host/MunieRemodexBridge/src/desktop-host.js"),
        codex: resources.appending(path: "Runtime/bin/codex"),
        stateDirectory: state, defaultProject: project)
      guard files.isExecutableFile(atPath: configuration.node.path),
        files.isExecutableFile(atPath: configuration.codex.path),
        files.isReadableFile(atPath: configuration.entryPoint.path)
      else { throw DesktopHostFailure.resourcesUnavailable }
      return configuration
    }.value
  }
}

/// Owns a single packaged helper for its entire lifetime, including an unconfirmed stop.
/// Pipe writes are nonblocking and serialized so a wedged helper cannot freeze the UI or stop path.
actor DesktopPackagedRuntime: DesktopHostRuntime {
  private enum PipeRead: Sendable {
    case data(Data)
    case retry
    case failed
  }

  private struct PendingRequest {
    let continuation: CheckedContinuation<DesktopJSON, any Error>
    let deadline: Task<Void, Never>
    let ownershipEpoch: UInt64
    let changesOwnership: Bool
  }

  private struct PendingWrite {
    let id: String
    let data: Data
    var offset = 0
  }

  private let configuration: DesktopRuntimeConfiguration
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var diagnostics: FileHandle?
  private var events: AsyncStream<DesktopHostEvent>.Continuation?
  private var lineBuffer = DesktopHostLineBuffer()
  private var writeRetry: Task<Void, Never>?
  private var requests: [String: PendingRequest] = [:]
  private var writes: [PendingWrite] = []
  private var exitStatus: Int32?
  private var stopConfirmed = false
  private var ownership: DesktopProcessOwnership?
  private var ownershipConfirmed = false
  private var ownershipEpoch: UInt64 = 0
  private var generation = UUID()

  init(configuration: DesktopRuntimeConfiguration) {
    self.configuration = configuration
  }

  func launch() async throws -> AsyncStream<DesktopHostEvent> {
    guard process == nil else { throw DesktopHostFailure.alreadyRunning }
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    child.executableURL = configuration.node
    child.arguments = [configuration.entryPoint.path]
    child.currentDirectoryURL = configuration.defaultProject
    let inherited = ProcessInfo.processInfo.environment
    var environment: [String: String] = [:]
    for key in ["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"] {
      environment[key] = inherited[key]
    }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["MUNIE_HOST_STATE_DIR"] = configuration.stateDirectory.path
    environment["MUNIE_CODEX_BINARY"] = configuration.codex.path
    child.environment = environment
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = stderr
    let launchGeneration = UUID()
    generation = launchGeneration
    child.terminationHandler = { [weak self] terminated in
      let status = terminated.terminationStatus
      Task { await self?.didExit(status: status, generation: launchGeneration) }
    }
    let (stream, continuation) = AsyncStream<DesktopHostEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(64))
    events = continuation
    do {
      let descriptor = stdin.fileHandleForWriting.fileDescriptor
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
        fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0
      else {
        throw DesktopHostFailure.writeFailed
      }
      try child.run()
    } catch {
      continuation.finish()
      events = nil
      throw error
    }
    process = child
    exitStatus = nil
    stopConfirmed = false
    ownership = nil
    ownershipConfirmed = false
    input = stdin.fileHandleForWriting
    output = stdout.fileHandleForReading
    diagnostics = stderr.fileHandleForReading
    for handle in [stdout.fileHandleForReading, stderr.fileHandleForReading] {
      let flags = fcntl(handle.fileDescriptor, F_GETFL)
      guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw DesktopHostFailure.invalidProtocol
      }
    }
    // Explicitly close the parent's copies of child endpoints; EOF must be observable.
    try stdin.fileHandleForReading.close()
    try stdout.fileHandleForWriting.close()
    try stderr.fileHandleForWriting.close()
    lineBuffer = DesktopHostLineBuffer()
    armControlReader(generation: launchGeneration)
    // Independent readiness callbacks prevent an idle stderr pipe from blocking control output.
    // Read one bounded chunk without retaining or logging potentially sensitive diagnostics.
    stderr.fileHandleForReading.readabilityHandler = { handle in
      switch Self.readChunk(from: handle) {
      case .data(let data) where data.isEmpty:
        handle.readabilityHandler = nil
      case .failed:
        handle.readabilityHandler = nil
      default:
        break
      }
    }
    return stream
  }

  func request(_ method: String, params: DesktopJSON = .object([:])) async throws -> DesktopJSON {
    guard let process, process.isRunning, input != nil else {
      throw DesktopHostFailure.notRunning
    }
    guard requests.count < 16 else { throw DesktopHostFailure.tooManyRequests }
    let id = UUID().uuidString
    var data = try JSONEncoder().encode(
      DesktopHostRequest(id: id, method: method, params: params))
    guard data.count <= 32_768 else { throw DesktopHostFailure.oversizedFrame }
    data.append(10)
    let timeout: Duration = method == "stop" ? .seconds(45) : .seconds(20)
    let changesOwnership = ["start", "retry", "project/set", "pairing/reset", "devices/revoke"]
      .contains(method)
    if changesOwnership {
      ownershipEpoch &+= 1
      ownershipConfirmed = false
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let deadline = Task { [weak self] in
          do { try await Task.sleep(for: timeout) } catch { return }
          await self?.expire(id)
        }
        requests[id] = PendingRequest(
          continuation: continuation, deadline: deadline, ownershipEpoch: ownershipEpoch,
          changesOwnership: changesOwnership)
        writes.append(PendingWrite(id: id, data: data))
        drainWrites()
      }
    } onCancel: {
      Task { await self.cancelRequest(id) }
    }
  }

  func shutdown() async throws {
    guard let process else { return }
    if !stopConfirmed {
      if process.isRunning {
        let result = try await request("stop")
        guard result["cleanupConfirmed"]?.boolean == true,
          result["state"]?.string == "stopped"
        else { throw DesktopHostFailure.cleanupUnconfirmed }
      } else {
        guard ownershipConfirmed, let ownership,
          await DesktopCleanupVerifier.verify(ownership, configuration: configuration)
        else { throw DesktopHostFailure.cleanupUnconfirmed }
      }
      stopConfirmed = true
    }
    if process.isRunning {
      // The helper exits on stdin EOF only after its own cleanup gate has passed.
      try input?.close()
      input = nil
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while process.isRunning, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    guard !process.isRunning, stopConfirmed else {
      throw DesktopHostFailure.cleanupUnconfirmed
    }
    try input?.close()
    input = nil
    output?.readabilityHandler = nil
    diagnostics?.readabilityHandler = nil
    writeRetry?.cancel()
    try output?.close()
    try diagnostics?.close()
    writeRetry = nil
    output = nil
    diagnostics = nil
    self.process = nil
    ownership = nil
    ownershipConfirmed = false
    events?.finish()
    events = nil
  }

  private func receive(_ frame: Data, generation: UUID) throws {
    guard generation == self.generation else { return }
    let envelope = try DesktopHostEnvelope.decode(frame)
    if let id = envelope.id {
      guard let pending = requests.removeValue(forKey: id) else { return }
      pending.deadline.cancel()
      if let error = envelope.error {
        pending.continuation.resume(throwing: error)
      } else if let result = envelope.result {
        if pending.changesOwnership, pending.ownershipEpoch == ownershipEpoch,
          result["state"]?.string == "running", let process,
          let recorded = DesktopProcessOwnership(
            status: result, expectedOwner: process.processIdentifier)
        {
          ownership = recorded
          ownershipConfirmed = true
        }
        pending.continuation.resume(returning: result)
      }
    } else if let event = envelope.event {
      if let status = envelope.data, let process,
        let recorded = DesktopProcessOwnership(
          status: status, expectedOwner: process.processIdentifier), recorded != ownership
      {
        // Events can precede a restart response. Only its matching response commits ownership.
        ownership = recorded
        ownershipConfirmed = false
      }
      events?.yield(.message(name: event, data: envelope.data ?? .null))
    }
  }

  /// Local integration fixtures use the PID to test an actual helper crash without model work.
  func helperProcessIdentifier() -> Int32? {
    guard let process, process.isRunning else { return nil }
    return process.processIdentifier
  }

  private func armControlReader(generation: UUID) {
    guard generation == self.generation, let output else { return }
    output.readabilityHandler = { [weak self] handle in
      // Pause until the actor consumes this chunk, bounding queued data to one read.
      handle.readabilityHandler = nil
      switch Self.readChunk(from: handle) {
      case .data(let chunk):
        Task { await self?.consume(chunk, generation: generation) }
      case .retry:
        Task { await self?.armControlReader(generation: generation) }
      case .failed:
        Task { await self?.protocolFailed(generation: generation) }
      }
    }
  }

  private nonisolated static func readChunk(from handle: FileHandle) -> PipeRead {
    var bytes = [UInt8](repeating: 0, count: 65_536)
    let count = bytes.withUnsafeMutableBytes { buffer in
      Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
    }
    if count >= 0 { return .data(Data(bytes.prefix(count))) }
    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return .retry }
    return .failed
  }

  private func consume(_ chunk: Data, generation: UUID) {
    guard generation == self.generation else { return }
    do {
      if chunk.isEmpty {
        try lineBuffer.finish()
        return
      }
      for byte in chunk {
        if let frame = try lineBuffer.append(byte) { try receive(frame, generation: generation) }
      }
      armControlReader(generation: generation)
    } catch {
      protocolFailed(generation: generation)
    }
  }

  private func drainWrites() {
    writeRetry?.cancel()
    writeRetry = nil
    guard let input else { return }
    while !writes.isEmpty {
      let written = writes[0].data.withUnsafeBytes { bytes in
        Darwin.write(
          input.fileDescriptor, bytes.baseAddress?.advanced(by: writes[0].offset),
          bytes.count - writes[0].offset)
      }
      if written > 0 {
        writes[0].offset += written
        if writes[0].offset == writes[0].data.count { writes.removeFirst() }
      } else if written < 0, errno == EINTR {
        continue
      } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        writeRetry = Task { [weak self] in
          do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
          await self?.drainWrites()
        }
        return
      } else {
        failRequests(DesktopHostFailure.writeFailed)
        return
      }
    }
  }

  private func expire(_ id: String) {
    guard let pending = requests.removeValue(forKey: id) else { return }
    pending.continuation.resume(throwing: DesktopHostFailure.timedOut)
  }

  private func cancelRequest(_ id: String) {
    guard let pending = requests.removeValue(forKey: id) else { return }
    pending.deadline.cancel()
    pending.continuation.resume(throwing: CancellationError())
  }

  private func failRequests(_ error: any Error) {
    let pending = requests.values
    requests.removeAll()
    writes.removeAll()
    writeRetry?.cancel()
    writeRetry = nil
    for request in pending {
      request.deadline.cancel()
      request.continuation.resume(throwing: error)
    }
  }

  private func didExit(status: Int32, generation: UUID) {
    guard generation == self.generation else { return }
    exitStatus = status
    failRequests(DesktopHostFailure.helperExited)
    events?.yield(.exited(status: status))
    // Keep the process reference: a crash is not evidence that its owned work was cleaned up.
  }

  private func protocolFailed(generation: UUID) {
    guard generation == self.generation else { return }
    failRequests(DesktopHostFailure.invalidProtocol)
    events?.yield(.protocolFailure)
  }
}
