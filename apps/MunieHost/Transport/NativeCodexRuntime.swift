import Darwin
import Foundation
import MunieExecutionHost

public struct NativeCodexRuntime: Sendable {
  public let executable: URL
  public let guardian: URL
  public let codexHome: URL
  public let hostState: URL

  public init(executable: URL, guardian: URL, codexHome: URL, hostState: URL) {
    self.executable = executable
    self.guardian = guardian
    self.codexHome = codexHome
    self.hostState = hostState
  }

  /// Uses the Mac's existing account in a dedicated, private Codex home with no personal MCP config.
  /// This method is an explicit local host setup action; mobile never supplies paths or credentials.
  public func prepare(usingLocalLoginAt source: URL) throws {
    try NativeCredentialStorage.prepare(home: codexHome, source: source)
  }

  public func adapter(for directory: URL) async throws -> any CodexExecutionAdapter {
    let manager = FileManager.default
    guard manager.isExecutableFile(atPath: executable.path),
      manager.isExecutableFile(atPath: guardian.path)
    else { throw NativeRuntimeError.executableUnavailable }
    var limits = CodexTransportLimits()
    limits.readTimeout = .seconds(300)
    limits.sessionTimeout = .seconds(900)
    // The outer profile protects the service's enrollment/history/ledger from native tools.
    // Codex itself retains read-only/on-request tool policy and its own sandbox.
    let protected = hostState.standardizedFileURL.path
    guard !protected.contains("\n"), !protected.contains("\""), !protected.contains("\\") else {
      throw NativeRuntimeError.invalidPath
    }
    let profile =
      "(version 1)(allow default)(deny file-read* file-write* (subpath \"\(protected)\"))"
    let environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
      "HOME": manager.homeDirectoryForCurrentUser.path,
      "CODEX_HOME": codexHome.path,
      "TMPDIR": NSTemporaryDirectory(),
      "LANG": "en_US.UTF-8",
    ]
    let transport = try CodexStdioTransport(
      executableURL: guardian,
      arguments: [
        String(ProcessInfo.processInfo.processIdentifier), "/usr/bin/sandbox-exec", "-p", profile,
        executable.path, "app-server",
      ],
      environment: environment, workingDirectoryURL: directory, limits: limits)
    do {
      let adapter = try CodexAppServer(
        transport: transport, workingDirectoryURL: directory,
        codexHomeURL: codexHome)
      try await adapter.initialize()
      return adapter
    } catch {
      do { _ = try await transport.shutdown() } catch { throw NativeRuntimeError.cleanupFailed }
      throw error
    }
  }
}

public enum NativeRuntimeError: Error, Equatable, Sendable {
  case loginRequired, executableUnavailable, invalidPath, cleanupFailed, insecureCredentials
}

/// Setup never repairs or follows an existing credential object. All reads and writes use held
/// descriptors; a private temporary copy is published only after the complete source is validated.
private enum NativeCredentialStorage {
  static let maximumBytes = 1_048_576

  static func prepare(home: URL, source: URL) throws {
    let parent = home.deletingLastPathComponent()
    guard validPath(home), canonical(parent.path, matches: parent.path) else {
      throw NativeRuntimeError.insecureCredentials
    }
    let created = mkdir(home.path, 0o700) == 0
    guard created || errno == EEXIST else { throw NativeRuntimeError.insecureCredentials }
    let directory = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard directory >= 0 else { throw NativeRuntimeError.insecureCredentials }
    defer { Darwin.close(directory) }
    // Only this invocation's new object may have permissions fixed (for a restrictive umask).
    if created, fchmod(directory, 0o700) != 0 { throw NativeRuntimeError.insecureCredentials }
    try validateDirectory(directory, at: home)
    if try validateAuth(in: directory) { return }

    let data = try readSource(source)
    try validateDirectory(directory, at: home)
    let temporary = ".auth-\(UUID().uuidString)"
    let destination = openat(
      directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard destination >= 0 else { throw NativeRuntimeError.insecureCredentials }
    defer {
      Darwin.close(destination)
      unlinkat(directory, temporary, 0)
    }
    guard fchmod(destination, 0o600) == 0 else { throw NativeRuntimeError.insecureCredentials }
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { throw NativeRuntimeError.insecureCredentials }
      var offset = 0
      while offset < bytes.count {
        let count = write(destination, base.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw NativeRuntimeError.insecureCredentials }
        offset += count
      }
    }
    _ = try privateFile(destination)
    try validateDirectory(directory, at: home)
    guard fsync(destination) == 0,
      renameatx_np(directory, temporary, directory, "auth.json", UInt32(RENAME_EXCL)) == 0,
      fsync(directory) == 0, try validateAuth(in: directory)
    else { throw NativeRuntimeError.insecureCredentials }
    try validateDirectory(directory, at: home)
  }

  private static func readSource(_ source: URL) throws -> Data {
    guard validPath(source) else { throw NativeRuntimeError.insecureCredentials }
    let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
      if errno == ENOENT { throw NativeRuntimeError.loginRequired }
      throw NativeRuntimeError.insecureCredentials
    }
    defer { Darwin.close(descriptor) }
    let before = try privateFile(descriptor)
    guard canonical(source.path, matches: source.path) else {
      throw NativeRuntimeError.insecureCredentials
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0, data.count + count <= maximumBytes else {
        throw NativeRuntimeError.insecureCredentials
      }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    let after = try privateFile(descriptor)
    var named = stat()
    guard lstat(source.path, &named) == 0, sameFile(after, named),
      canonical(source.path, matches: source.path), data.count == before.st_size,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw NativeRuntimeError.insecureCredentials }
    return data
  }

  private static func validateAuth(in directory: Int32) throws -> Bool {
    let descriptor = openat(directory, "auth.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
      if errno == ENOENT { return false }
      throw NativeRuntimeError.insecureCredentials
    }
    defer { Darwin.close(descriptor) }
    let held = try privateFile(descriptor)
    var named = stat()
    guard fstatat(directory, "auth.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
      sameFile(held, named)
    else { throw NativeRuntimeError.insecureCredentials }
    return true
  }

  private static func privateFile(_ descriptor: Int32) throws -> stat {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600, info.st_nlink == 1,
      info.st_size > 0, info.st_size <= maximumBytes, noExtendedACL(descriptor)
    else { throw NativeRuntimeError.insecureCredentials }
    return info
  }

  private static func validateDirectory(_ descriptor: Int32, at home: URL) throws {
    var held = stat()
    var named = stat()
    guard fstat(descriptor, &held) == 0, lstat(home.path, &named) == 0,
      held.st_mode & S_IFMT == S_IFDIR, held.st_uid == geteuid(),
      held.st_mode & 0o7777 == 0o700, sameFile(held, named),
      canonical(home.path, matches: home.path), noExtendedACL(descriptor)
    else { throw NativeRuntimeError.insecureCredentials }
  }

  private static func sameFile(_ held: stat, _ named: stat) -> Bool {
    held.st_dev == named.st_dev && held.st_ino == named.st_ino && held.st_mode == named.st_mode
      && held.st_uid == named.st_uid && held.st_nlink == named.st_nlink
  }

  private static func noExtendedACL(_ descriptor: Int32) -> Bool {
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_valid(acl) == 0 else { return false }
    var entry: acl_entry_t?
    return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == -1 && errno == EINVAL
  }

  private static func validPath(_ url: URL) -> Bool {
    url.isFileURL && url.path.hasPrefix("/") && !url.path.utf8.contains(0)
  }

  private static func canonical(_ path: String, matches expected: String) -> Bool {
    guard let pointer = realpath(path, nil) else { return false }
    defer { free(pointer) }
    return String(cString: pointer).utf8.elementsEqual(expected.utf8)
  }
}
