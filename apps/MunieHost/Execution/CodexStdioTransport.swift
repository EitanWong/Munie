import Darwin
import Foundation

public protocol CodexRPCTransport: Sendable {
  func send(_ frame: CodexJSON) async throws
  func receive() async throws -> CodexJSON
  func shutdown() async throws -> CodexTransportCleanup
}

/// Limits apply to one bounded research session, not an indefinitely running host service.
public struct CodexTransportLimits: Sendable {
  public var maximumFrameBytes = 1_048_576
  public var maximumStdoutBytes = 33_554_432
  public var maximumStderrBytes = 1_048_576
  public var maximumStdinBytes = 33_554_432
  public var maximumQueuedFrames = 256
  public var readTimeout: Duration = .seconds(60)
  public var writeTimeout: Duration = .seconds(5)
  public var sessionTimeout: Duration = .seconds(300)
  public var shutdownGrace: Duration = .seconds(1)

  public init() {}
}

public struct CodexTransportCleanup: Sendable, Equatable {
  /// waitpid's raw status: zero is a successful normal exit; signal exits remain distinguishable.
  public let leaderExitStatus: Int32?
  public let stdoutEOF: Bool
  public let stderrEOF: Bool
  public let groupGone: Bool
  public let escalated: Bool
  public let stdinBytes: Int
  public let stdoutBytes: Int
  public let stderrBytes: Int
  public let withinLimits: Bool

  public init(
    leaderExitStatus: Int32?, stdoutEOF: Bool, stderrEOF: Bool, groupGone: Bool, escalated: Bool,
    stdinBytes: Int, stdoutBytes: Int, stderrBytes: Int, withinLimits: Bool = true
  ) {
    self.leaderExitStatus = leaderExitStatus
    self.stdoutEOF = stdoutEOF
    self.stderrEOF = stderrEOF
    self.groupGone = groupGone
    self.escalated = escalated
    self.stdinBytes = stdinBytes
    self.stdoutBytes = stdoutBytes
    self.stderrBytes = stderrBytes
    self.withinLimits = withinLimits
  }

  public var complete: Bool {
    leaderExitStatus != nil && stdoutEOF && stderrEOF && groupGone
  }
}

public enum CodexTransportError: Error, Sendable, Equatable {
  case invalidConfiguration
  case launchFailed(code: Int32)
  case systemFailure(code: Int32)
  case closed
  case sendInProgress
  case receiveInProgress
  case shutdownInProgress
  case timeout
  case cancelled
  case frameTooLarge
  case outputLimit
  case inputLimit
  case queueLimit
  case invalidFrame
  case unexpectedEOF
  case processExited(status: Int32)
  case cleanupIncomplete
}

/// Host administration supplies every launch parameter; the inherited personal environment is absent.
/// Nonblocking descriptors belong to this actor. No detached readers or unchecked Sendable wrappers exist.
public actor CodexStdioTransport: CodexRPCTransport {
  private let limits: CodexTransportLimits
  private let clock = ContinuousClock()
  private let started: ContinuousClock.Instant
  private let processID: pid_t
  public nonisolated var processGroupID: Int32 { processID }
  private var input: Int32
  private var output: Int32
  private var errorOutput: Int32
  private var line = Data()
  private var frames: [CodexJSON] = []
  private var inputBytes = 0
  private var outputBytes = 0
  private var errorBytes = 0
  private var outputEOF = false
  private var errorEOF = false
  private var exitStatus: Int32?
  private var sending = false
  private var receiving = false
  private var stopping = false
  private var primaryFailure: CodexTransportError?
  private var cleanup: CodexTransportCleanup?

  public init(
    executableURL: URL, arguments: [String], environment: [String: String],
    workingDirectoryURL: URL, limits: CodexTransportLimits = .init()
  ) throws {
    guard limits.maximumFrameBytes > 0, limits.maximumFrameBytes <= 16_777_216,
      limits.maximumStdoutBytes >= limits.maximumFrameBytes,
      limits.maximumStdoutBytes <= 268_435_456,
      limits.maximumStderrBytes > 0, limits.maximumStderrBytes <= 16_777_216,
      limits.maximumStdinBytes >= limits.maximumFrameBytes,
      limits.maximumStdinBytes <= 268_435_456,
      (1...4096).contains(limits.maximumQueuedFrames),
      limits.readTimeout > .zero, limits.readTimeout <= .seconds(300),
      limits.writeTimeout > .zero, limits.writeTimeout <= .seconds(60),
      limits.sessionTimeout > .zero, limits.sessionTimeout <= .seconds(3600),
      limits.shutdownGrace > .zero, limits.shutdownGrace <= .seconds(10),
      executableURL.isFileURL, executableURL.path.hasPrefix("/"),
      workingDirectoryURL.isFileURL, workingDirectoryURL.path.hasPrefix("/"),
      !executableURL.path.utf8.contains(0), !workingDirectoryURL.path.utf8.contains(0),
      arguments.count <= 256,
      arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 65_536 }),
      environment.count <= 256,
      environment.allSatisfy({
        !$0.key.isEmpty && $0.key.utf8.count <= 65_536
          && !$0.key.contains("=") && !$0.key.utf8.contains(0)
          && !$0.value.utf8.contains(0) && $0.value.utf8.count <= 65_536
      })
    else { throw CodexTransportError.invalidConfiguration }
    var executableInfo = stat()
    var directoryInfo = stat()
    guard stat(executableURL.path, &executableInfo) == 0,
      executableInfo.st_mode & S_IFMT == S_IFREG, access(executableURL.path, X_OK) == 0,
      stat(workingDirectoryURL.path, &directoryInfo) == 0,
      directoryInfo.st_mode & S_IFMT == S_IFDIR
    else { throw CodexTransportError.invalidConfiguration }
    let spawned = try Self.spawn(
      executable: executableURL.path, arguments: arguments, environment: environment,
      directory: workingDirectoryURL.path)
    self.limits = limits
    started = ContinuousClock().now
    processID = spawned.pid
    input = spawned.input
    output = spawned.output
    errorOutput = spawned.error
  }

  deinit {
    // Await shutdown for verified cleanup. A forgotten owner receives bounded best-effort cleanup only.
    if cleanup == nil {
      _ = kill(-processID, SIGKILL)
      if input >= 0 { close(input) }
      if output >= 0 { close(output) }
      if errorOutput >= 0 { close(errorOutput) }
      if exitStatus == nil {
        let ownedLeader = processID
        DispatchQueue.global().async {
          let clock = ContinuousClock()
          let deadline = clock.now.advanced(by: .seconds(3))
          var status: Int32 = 0
          repeat {
            let result = waitpid(ownedLeader, &status, WNOHANG)
            if result == ownedLeader || (result < 0 && errno == ECHILD) { return }
            usleep(2_000)
          } while clock.now < deadline
        }
      }
    }
  }

  public func send(_ frame: CodexJSON) async throws {
    guard !sending else { throw CodexTransportError.sendInProgress }
    sending = true
    defer { sending = false }
    do {
      try ensureActive()
      var data: Data
      do { data = try frame.encoded(maximumBytes: limits.maximumFrameBytes) } catch CodexJSONError
        .sizeLimit
      { throw CodexTransportError.frameTooLarge } catch { throw CodexTransportError.invalidFrame }
      guard data.count <= limits.maximumFrameBytes else { throw CodexTransportError.frameTooLarge }
      data.append(10)
      guard inputBytes <= limits.maximumStdinBytes - data.count else {
        throw CodexTransportError.inputLimit
      }
      let deadline = clock.now.advanced(by: limits.writeTimeout)
      var offset = 0
      while offset < data.count {
        try ensureActive()
        try pump()
        guard input >= 0 else { throw CodexTransportError.closed }
        let written = data.withUnsafeBytes { bytes in
          Darwin.write(input, bytes.baseAddress!.advanced(by: offset), data.count - offset)
        }
        if written > 0 {
          offset += written
          inputBytes += written
          continue
        }
        if written < 0 && errno == EINTR { continue }
        if written < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
          throw CodexTransportError.systemFailure(code: errno)
        }
        guard clock.now < deadline else { throw CodexTransportError.timeout }
        try await clock.sleep(for: .milliseconds(2))
      }
    } catch {
      let failure = record(error)
      _ = try? await shutdown()
      throw failure
    }
  }

  public func receive() async throws -> CodexJSON {
    guard !receiving else { throw CodexTransportError.receiveInProgress }
    receiving = true
    defer { receiving = false }
    let deadline = clock.now.advanced(by: limits.readTimeout)
    do {
      while true {
        try ensureActive()
        try pump()
        if !frames.isEmpty { return frames.removeFirst() }
        if outputEOF {
          if let exitStatus, exitStatus != 0 {
            throw CodexTransportError.processExited(status: exitStatus)
          }
          throw CodexTransportError.unexpectedEOF
        }
        guard clock.now < deadline else { throw CodexTransportError.timeout }
        try await clock.sleep(for: .milliseconds(2))
      }
    } catch {
      let failure = record(error)
      _ = try? await shutdown()
      throw failure
    }
  }

  /// Cleanup ignores caller cancellation and always attempts EOF, TERM, KILL and bounded reaping.
  public func shutdown() async throws -> CodexTransportCleanup {
    if let cleanup {
      guard cleanup.complete else { throw CodexTransportError.cleanupIncomplete }
      if primaryFailure == nil && !cleanup.withinLimits { throw CodexTransportError.outputLimit }
      return cleanup
    }
    guard !stopping else { throw CodexTransportError.shutdownInProgress }
    stopping = true
    let hadPrimaryFailure = primaryFailure != nil
    closeDescriptor(&input)
    var escalated = false
    for signal in [Int32(0), SIGTERM, SIGKILL] {
      if signal != 0 {
        escalated = true
        _ = kill(-processID, signal)
      }
      let deadline = clock.now.advanced(by: limits.shutdownGrace)
      repeat {
        do { try pump(discardFrames: true) } catch { _ = record(error) }
        reap()
        if exitStatus != nil && outputEOF && errorEOF && groupIsGone() { break }
        await Self.cleanupPause()
      } while clock.now < deadline
      if exitStatus != nil && outputEOF && errorEOF && groupIsGone() { break }
    }
    reap()
    let result = CodexTransportCleanup(
      leaderExitStatus: exitStatus, stdoutEOF: outputEOF, stderrEOF: errorEOF,
      groupGone: groupIsGone(), escalated: escalated,
      stdinBytes: inputBytes, stdoutBytes: outputBytes, stderrBytes: errorBytes,
      withinLimits: outputBytes <= limits.maximumStdoutBytes
        && errorBytes <= limits.maximumStderrBytes)
    closeDescriptor(&output)
    closeDescriptor(&errorOutput)
    line.removeAll()
    frames.removeAll()
    cleanup = result
    guard result.complete else { throw CodexTransportError.cleanupIncomplete }
    if !hadPrimaryFailure && !result.withinLimits { throw CodexTransportError.outputLimit }
    return result
  }

  private func ensureActive() throws {
    if let primaryFailure { throw primaryFailure }
    guard !stopping, cleanup == nil else { throw CodexTransportError.closed }
    guard !Task.isCancelled else { throw CodexTransportError.cancelled }
    guard clock.now < started.advanced(by: limits.sessionTimeout) else {
      throw CodexTransportError.timeout
    }
  }

  private func record(_ error: any Error) -> CodexTransportError {
    let failure: CodexTransportError
    if let transport = error as? CodexTransportError {
      failure = transport
    } else if error is CancellationError {
      failure = .cancelled
    } else {
      failure = .invalidFrame
    }
    if primaryFailure == nil { primaryFailure = failure }
    return primaryFailure ?? failure
  }

  private func pump(discardFrames: Bool = false) throws {
    // Read stderr first, including its final tail; it never enters frames, errors or cleanup text.
    try drain(errorStream: true, discardFrames: discardFrames)
    try drain(errorStream: false, discardFrames: discardFrames)
    reap()
  }

  private func drain(errorStream: Bool, discardFrames: Bool) throws {
    let descriptor = errorStream ? errorOutput : output
    guard descriptor >= 0 else { return }
    var scratch = [UInt8](repeating: 0, count: 16_384)
    for _ in 0..<8 {
      let count = Darwin.read(descriptor, &scratch, scratch.count)
      if count == 0 {
        if errorStream {
          errorEOF = true
          closeDescriptor(&errorOutput)
        } else {
          outputEOF = true
          closeDescriptor(&output)
          if !line.isEmpty && !discardFrames { throw CodexTransportError.invalidFrame }
        }
        return
      }
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        throw CodexTransportError.systemFailure(code: errno)
      }
      if errorStream {
        errorBytes += count
        if errorBytes > limits.maximumStderrBytes && !discardFrames {
          throw CodexTransportError.outputLimit
        }
      } else {
        outputBytes += count
        if outputBytes > limits.maximumStdoutBytes && !discardFrames {
          throw CodexTransportError.outputLimit
        }
        if discardFrames { continue }
        for byte in scratch.prefix(count) {
          if byte == 10 {
            guard !line.isEmpty else { throw CodexTransportError.invalidFrame }
            let frame: CodexJSON
            do { frame = try CodexJSON.decode(line) } catch {
              throw CodexTransportError.invalidFrame
            }
            line.removeAll(keepingCapacity: true)
            guard frames.count < limits.maximumQueuedFrames else {
              throw CodexTransportError.queueLimit
            }
            frames.append(frame)
          } else {
            guard line.count < limits.maximumFrameBytes else {
              throw CodexTransportError.frameTooLarge
            }
            line.append(byte)
          }
        }
      }
    }
  }

  private func reap() {
    guard exitStatus == nil else { return }
    var status: Int32 = 0
    let result = waitpid(processID, &status, WNOHANG)
    if result == processID { exitStatus = status }
  }

  private func groupIsGone() -> Bool {
    if kill(-processID, 0) == 0 { return false }
    return errno == ESRCH
  }

  private func closeDescriptor(_ descriptor: inout Int32) {
    if descriptor >= 0 {
      close(descriptor)
      descriptor = -1
    }
  }

  private static func cleanupPause() async {
    // Checked continuation, rather than Task.sleep, still waits when the caller is cancelled.
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) {
        continuation.resume()
      }
    }
  }

  private static func spawn(
    executable: String, arguments: [String], environment: [String: String], directory: String
  ) throws -> (pid: pid_t, input: Int32, output: Int32, error: Int32) {
    var stdinPipe: [Int32] = [-1, -1]
    var stdoutPipe: [Int32] = [-1, -1]
    var stderrPipe: [Int32] = [-1, -1]
    var succeeded = false
    defer {
      for fd in [stdinPipe[0], stdoutPipe[1], stderrPipe[1]] where fd >= 0 { close(fd) }
      if !succeeded {
        for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] where fd >= 0 { close(fd) }
      }
    }
    func createPipe(_ pair: inout [Int32]) throws {
      guard pipe(&pair) == 0 else { throw CodexTransportError.systemFailure(code: errno) }
      for descriptor in pair {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
          throw CodexTransportError.systemFailure(code: errno)
        }
      }
    }
    try createPipe(&stdinPipe)
    try createPipe(&stdoutPipe)
    try createPipe(&stderrPipe)
    for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] {
      guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
        throw CodexTransportError.systemFailure(code: errno)
      }
    }
    guard fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1) == 0 else {
      throw CodexTransportError.systemFailure(code: errno)
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var result = posix_spawn_file_actions_init(&actions)
    guard result == 0 else { throw CodexTransportError.launchFailed(code: result) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    result = posix_spawnattr_init(&attributes)
    guard result == 0 else { throw CodexTransportError.launchFailed(code: result) }
    defer { posix_spawnattr_destroy(&attributes) }
    for (source, destination) in [(stdinPipe[0], 0), (stdoutPipe[1], 1), (stderrPipe[1], 2)] {
      result = posix_spawn_file_actions_adddup2(&actions, source, Int32(destination))
      guard result == 0 else { throw CodexTransportError.launchFailed(code: result) }
    }
    if #available(macOS 26, *) {
      result = posix_spawn_file_actions_addchdir(&actions, directory)
    } else {
      result = posix_spawn_file_actions_addchdir_np(&actions, directory)
    }
    guard result == 0 else { throw CodexTransportError.launchFailed(code: result) }
    result = posix_spawnattr_setpgroup(&attributes, 0)
    guard result == 0 else { throw CodexTransportError.launchFailed(code: result) }
    var mask = sigset_t()
    sigemptyset(&mask)
    result = posix_spawnattr_setsigmask(&attributes, &mask)
    guard result == 0 else { throw CodexTransportError.launchFailed(code: result) }
    for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD] {
      sigaddset(&mask, signal)
    }
    result = posix_spawnattr_setsigdefault(&attributes, &mask)
    guard result == 0 else { throw CodexTransportError.launchFailed(code: result) }
    result = posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
          | POSIX_SPAWN_CLOEXEC_DEFAULT))
    guard result == 0 else { throw CodexTransportError.launchFailed(code: result) }
    let argv = ([executable] + arguments).map { strdup($0) }
    let envp = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) }
    defer { for pointer in argv + envp { free(pointer) } }
    guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else {
      throw CodexTransportError.systemFailure(code: ENOMEM)
    }
    var process: pid_t = 0
    result = (argv + [nil]).withUnsafeBufferPointer { arguments in
      (envp + [nil]).withUnsafeBufferPointer { environment in
        posix_spawn(
          &process, executable, &actions, &attributes,
          UnsafeMutablePointer(mutating: arguments.baseAddress!),
          UnsafeMutablePointer(mutating: environment.baseAddress!))
      }
    }
    guard result == 0 else { throw CodexTransportError.launchFailed(code: result) }
    succeeded = true
    return (process, stdinPipe[1], stdoutPipe[0], stderrPipe[0])
  }
}
