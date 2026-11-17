import Darwin
import Foundation
import Synchronization
import Testing

@testable import MunieProductHost

struct ProductPersistenceTests {
  @Test func missingAndPrivateRegularHistoryStillLoad() throws {
    let root = try persistenceFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProductPersistence(directory: root.appending(path: "state"))
    let id = UUID()
    #expect(try store.load(hostID: id).hostID == id)
    var saved = ProductState(hostID: id)
    saved.revision = 42
    try store.save(saved)
    #expect(try store.load(hostID: id).revision == 42)
  }

  @Test func historyFIFOIsRejectedBeforeWaitingForAWriter() throws {
    let root = try persistenceFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appending(path: "state")
    try FileManager.default.createDirectory(
      at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let fifo = state.appending(path: "history.json")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let outcome = Mutex<ProductHostError?>(nil)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      do {
        let store = try ProductPersistence(directory: state)
        _ = try store.load(hostID: UUID())
      } catch {
        outcome.withLock { $0 = error as? ProductHostError }
      }
      finished.signal()
    }
    let completedWithoutWriter = finished.wait(timeout: .now() + .seconds(1)) == .success
    if !completedWithoutWriter {
      // A regression must fail promptly without leaving a blocked worker in the test process.
      let rescue = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
      defer { if rescue >= 0 { Darwin.close(rescue) } }
      #expect(finished.wait(timeout: .now() + .seconds(2)) == .success)
    }
    #expect(completedWithoutWriter)
    #expect(outcome.withLock { $0 } == .invalidStorage)
  }

  @Test(arguments: ["symlink", "hardlink", "public", "directory"])
  func nonprivateOrNonregularHistoryStillFailsClosed(kind: String) throws {
    let root = try persistenceFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ProductPersistence(directory: root.appending(path: "state"))
    let original = root.appending(path: "original")
    try Data("private synthetic content".utf8).write(to: original)
    #expect(chmod(original.path, 0o600) == 0)
    let history = store.directory.appending(path: "history.json")
    switch kind {
    case "symlink": #expect(symlink(original.path, history.path) == 0)
    case "hardlink": #expect(link(original.path, history.path) == 0)
    case "public":
      try Data("{}".utf8).write(to: history)
      #expect(chmod(history.path, 0o644) == 0)
    default:
      #expect(mkdir(history.path, 0o700) == 0)
    }
    #expect(throws: ProductHostError.invalidStorage) { try store.load(hostID: UUID()) }
    #expect(try Data(contentsOf: original) == Data("private synthetic content".utf8))
  }
}

private func persistenceFixture() throws -> URL {
  let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
  defer { free(pointer) }
  let parent = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
  let root = parent.appending(path: "munie-persistence-\(UUID())")
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return root
}
