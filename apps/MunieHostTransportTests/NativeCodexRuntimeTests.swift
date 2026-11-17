import Darwin
import Foundation
import Synchronization
import Testing

@testable import MunieHostTransport

struct NativeCodexRuntimeTests {
  @Test func newPrivateHomeCopiesLoginAndExistingLoginIsReusedWithoutSource() throws {
    let fixture = try NativeLoginFixture()
    defer { fixture.remove() }
    // The ordinary Codex home may be searchable; its actual credential must remain private.
    #expect(chmod(fixture.root.path, 0o755) == 0)
    try fixture.runtime.prepare(usingLocalLoginAt: fixture.source)
    #expect(try Data(contentsOf: fixture.auth) == fixture.bytes)
    let home = try metadata(fixture.home)
    let auth = try metadata(fixture.auth)
    #expect(home.st_mode & 0o7777 == 0o700 && home.st_uid == geteuid())
    #expect(auth.st_mode & 0o7777 == 0o600 && auth.st_uid == geteuid() && auth.st_nlink == 1)
    #expect(try auth.st_ino != metadata(fixture.source).st_ino)
    try FileManager.default.removeItem(at: fixture.source)
    try fixture.runtime.prepare(usingLocalLoginAt: fixture.source)
    #expect(try Data(contentsOf: fixture.auth) == fixture.bytes)
    #expect(try metadata(fixture.auth).st_ino == auth.st_ino)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path) == ["auth.json"])
  }

  @Test func insecureExistingHomeIsRejectedWithoutChangingPermissionsOrLogin() throws {
    let fixture = try NativeLoginFixture()
    defer { fixture.remove() }
    try fixture.installExisting()
    #expect(chmod(fixture.home.path, 0o755) == 0)
    #expect(chmod(fixture.auth.path, 0o644) == 0)
    #expect(throws: NativeRuntimeError.insecureCredentials) {
      try fixture.runtime.prepare(usingLocalLoginAt: fixture.source)
    }
    #expect(try metadata(fixture.home).st_mode & 0o7777 == 0o755)
    #expect(try metadata(fixture.auth).st_mode & 0o7777 == 0o644)
    #expect(try Data(contentsOf: fixture.auth) == fixture.bytes)
  }

  @Test(arguments: ["public", "symlink", "dangling-symlink", "hardlink", "directory", "empty"])
  func insecureExistingAuthIsRejectedWithoutReplacement(kind: String) throws {
    let fixture = try NativeLoginFixture()
    defer { fixture.remove() }
    #expect(mkdir(fixture.home.path, 0o700) == 0)
    switch kind {
    case "public":
      try fixture.bytes.write(to: fixture.auth)
      #expect(chmod(fixture.auth.path, 0o644) == 0)
    case "symlink": #expect(symlink(fixture.source.path, fixture.auth.path) == 0)
    case "dangling-symlink":
      #expect(symlink(fixture.root.appending(path: "missing").path, fixture.auth.path) == 0)
    case "hardlink": #expect(link(fixture.source.path, fixture.auth.path) == 0)
    case "directory": #expect(mkdir(fixture.auth.path, 0o700) == 0)
    default:
      try Data().write(to: fixture.auth)
      #expect(chmod(fixture.auth.path, 0o600) == 0)
    }
    let before = try metadata(fixture.auth)
    #expect(throws: NativeRuntimeError.insecureCredentials) {
      try fixture.runtime.prepare(usingLocalLoginAt: fixture.source)
    }
    let after = try metadata(fixture.auth)
    #expect(before.st_ino == after.st_ino && before.st_mode == after.st_mode)
    #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
  }

  @Test(arguments: ["home", "parent"])
  func symbolicHomeOrAncestorCannotRedirectCredentialSetup(kind: String) throws {
    let fixture = try NativeLoginFixture()
    defer { fixture.remove() }
    let realHome = fixture.root.appending(path: "real-home")
    #expect(mkdir(realHome.path, 0o700) == 0)
    let chosen: URL
    if kind == "home" {
      #expect(symlink(realHome.path, fixture.home.path) == 0)
      chosen = fixture.home
    } else {
      let alias = fixture.root.appending(path: "alias")
      #expect(symlink(realHome.path, alias.path) == 0)
      chosen = alias.appending(path: "codex-home")
    }
    #expect(throws: NativeRuntimeError.insecureCredentials) {
      try fixture.runtime(home: chosen).prepare(usingLocalLoginAt: fixture.source)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: realHome.path).isEmpty)
  }

  @Test(arguments: ["public", "symlink", "hardlink", "directory", "empty", "oversized"])
  func unsafeImportSourceNeverPublishesAuth(kind: String) throws {
    let fixture = try NativeLoginFixture()
    defer { fixture.remove() }
    let original = fixture.root.appending(path: "original")
    switch kind {
    case "public": #expect(chmod(fixture.source.path, 0o644) == 0)
    case "symlink":
      try FileManager.default.moveItem(at: fixture.source, to: original)
      #expect(symlink(original.path, fixture.source.path) == 0)
    case "hardlink": #expect(link(fixture.source.path, original.path) == 0)
    case "directory":
      try FileManager.default.removeItem(at: fixture.source)
      #expect(mkdir(fixture.source.path, 0o700) == 0)
    case "empty": try Data().write(to: fixture.source)
    default: try Data(repeating: 42, count: 1_048_577).write(to: fixture.source)
    }
    #expect(throws: NativeRuntimeError.insecureCredentials) {
      try fixture.runtime.prepare(usingLocalLoginAt: fixture.source)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.auth.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).isEmpty)
  }

  @Test(arguments: ["auth", "source"])
  func credentialFIFOIsRejectedWithoutWaitingForAWriter(location: String) throws {
    let fixture = try NativeLoginFixture()
    defer { fixture.remove() }
    #expect(mkdir(fixture.home.path, 0o700) == 0)
    let fifo = location == "auth" ? fixture.auth : fixture.source
    if location == "source" { try FileManager.default.removeItem(at: fixture.source) }
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let result = Mutex<NativeRuntimeError?>(nil)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      do { try fixture.runtime.prepare(usingLocalLoginAt: fixture.source) } catch {
        result.withLock { $0 = error as? NativeRuntimeError }
      }
      completed.signal()
    }
    let rejectedWithoutWriter = completed.wait(timeout: .now() + .seconds(1)) == .success
    if !rejectedWithoutWriter {
      let rescue = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
      defer { if rescue >= 0 { Darwin.close(rescue) } }
      #expect(completed.wait(timeout: .now() + .seconds(2)) == .success)
    }
    #expect(rejectedWithoutWriter)
    #expect(result.withLock { $0 } == .insecureCredentials)
  }

  @Test(arguments: ["home", "auth", "source"])
  func extendedACLDoesNotBypassPrivateModeValidation(location: String) throws {
    let fixture = try NativeLoginFixture()
    defer { fixture.remove() }
    try fixture.installExisting()
    let path =
      location == "home" ? fixture.home : location == "auth" ? fixture.auth : fixture.source
    if location == "source" { try FileManager.default.removeItem(at: fixture.auth) }
    let chmod = Process()
    chmod.executableURL = URL(filePath: "/bin/chmod")
    chmod.arguments = ["+a", "user:\(NSUserName()) allow read", path.path]
    try chmod.run()
    chmod.waitUntilExit()
    #expect(chmod.terminationStatus == 0)
    #expect(throws: NativeRuntimeError.insecureCredentials) {
      try fixture.runtime.prepare(usingLocalLoginAt: fixture.source)
    }
  }
}

private struct NativeLoginFixture: Sendable {
  let root: URL
  let bytes = Data("{\"syntheticLogin\":true}".utf8)
  var home: URL { root.appending(path: "codex-home") }
  var auth: URL { home.appending(path: "auth.json") }
  var source: URL { root.appending(path: "source-auth.json") }
  var runtime: NativeCodexRuntime { runtime(home: home) }

  init() throws {
    let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(pointer) }
    root = URL(fileURLWithPath: String(cString: pointer), isDirectory: true).appending(
      path: "munie-native-login-\(UUID())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try bytes.write(to: source)
    guard chmod(source.path, 0o600) == 0 else { throw NativeRuntimeError.insecureCredentials }
  }

  func runtime(home: URL) -> NativeCodexRuntime {
    NativeCodexRuntime(
      executable: URL(filePath: "/usr/bin/true"), guardian: URL(filePath: "/usr/bin/true"),
      codexHome: home, hostState: root.appending(path: "state"))
  }

  func installExisting() throws {
    guard mkdir(home.path, 0o700) == 0 else { throw NativeRuntimeError.insecureCredentials }
    try bytes.write(to: auth)
    guard chmod(auth.path, 0o600) == 0 else { throw NativeRuntimeError.insecureCredentials }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private func metadata(_ url: URL) throws -> stat {
  var info = stat()
  guard lstat(url.path, &info) == 0 else { throw NativeRuntimeError.insecureCredentials }
  return info
}
