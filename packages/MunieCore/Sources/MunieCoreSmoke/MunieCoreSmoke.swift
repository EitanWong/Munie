import Foundation
import MunieCore

@main
struct MunieCoreSmoke {
  static func main() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MunieCoreSmoke-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("captures.json")
    let store = FileCaptureStore(fileURL: file)
    let record = try await store.save(text: "Smoke test: keep an idea 📝")
    let reopened = FileCaptureStore(fileURL: file)
    let restored = try await reopened.list()
    guard restored == [record] else { throw SmokeFailure.persistence }
    try await reopened.delete(id: record.id)
    guard try await FileCaptureStore(fileURL: file).list().isEmpty else {
      throw SmokeFailure.deletion
    }
    print("PASS capture → persist → reopen → delete → reopen")
  }

  private enum SmokeFailure: Error {
    case persistence
    case deletion
  }
}
