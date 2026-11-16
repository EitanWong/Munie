import Foundation
import Testing

@testable import MunieCore

struct FileCaptureStoreTests {
  @Test func missingFileStartsEmptyWithoutCreatingData() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = FileCaptureStore(fileURL: fixture.fileURL)
    #expect(try await store.list().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
  }

  @Test(arguments: ["", " ", "\n\t\r", "\u{2003}"])
  func rejectsBlankText(text: String) async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = FileCaptureStore(fileURL: fixture.fileURL)
    await #expect(throws: CaptureError.blankText) { try await store.save(text: text) }
    #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
  }

  @Test func preservesUnicodeAndInteriorWhitespace() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = FileCaptureStore(fileURL: fixture.fileURL)
    let record = try await store.save(text: " \n想法 👨‍👩‍👧‍👦\n  café\t ")
    #expect(record.text == "想法 👨‍👩‍👧‍👦\n  café")
    #expect(try await FileCaptureStore(fileURL: fixture.fileURL).list() == [record])
  }

  @Test func enforcesCharacterLimitAfterTrimming() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = FileCaptureStore(fileURL: fixture.fileURL)
    let accepted = String(repeating: "👨‍👩‍👧‍👦", count: FileCaptureStore.maximumTextLength)
    let record = try await store.save(text: "\n\(accepted) ")
    #expect(record.text == accepted)
    await #expect(
      throws: CaptureError.textTooLong(maximum: FileCaptureStore.maximumTextLength)
    ) { try await store.save(text: accepted + "!") }
    #expect(try await store.list() == [record])
  }

  @Test func saveAndDeleteSurviveReopening() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = FileCaptureStore(fileURL: fixture.fileURL)
    let first = try await store.save(text: "First")
    let second = try await store.save(text: "Second")
    let reopened = FileCaptureStore(fileURL: fixture.fileURL)
    #expect(try await reopened.list() == [second, first])
    try await reopened.delete(id: first.id)
    #expect(try await FileCaptureStore(fileURL: fixture.fileURL).list() == [second])
    try await reopened.delete(id: second.id)
    #expect(try await FileCaptureStore(fileURL: fixture.fileURL).list().isEmpty)
  }

  @Test func deletingMissingRecordPreservesExistingData() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = FileCaptureStore(fileURL: fixture.fileURL)
    let record = try await store.save(text: "Keep")
    let original = try Data(contentsOf: fixture.fileURL)
    let missing = UUID()
    await #expect(throws: CaptureError.recordNotFound(missing)) {
      try await store.delete(id: missing)
    }
    #expect(try Data(contentsOf: fixture.fileURL) == original)
    #expect(try await store.list() == [record])
  }

  @Test(arguments: [
    "not json", "{}", "{\"schemaVersion\":1}",
    "{\"schemaVersion\":1,\"records\":[{\"id\":\"bad\"}]}",
  ])
  func corruptFileIsNotOverwritten(contents: String) async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(contents)
    let original = try Data(contentsOf: fixture.fileURL)
    let store = FileCaptureStore(fileURL: fixture.fileURL)
    await #expect(throws: CaptureError.corruptData) { try await store.list() }
    await #expect(throws: CaptureError.corruptData) { try await store.save(text: "New") }
    await #expect(throws: CaptureError.corruptData) { try await store.delete(id: UUID()) }
    #expect(try Data(contentsOf: fixture.fileURL) == original)
  }

  @Test func unsupportedVersionIsNotOverwritten() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    try fixture.write("{\"schemaVersion\":2,\"records\":[]}")
    let original = try Data(contentsOf: fixture.fileURL)
    let store = FileCaptureStore(fileURL: fixture.fileURL)
    await #expect(throws: CaptureError.unsupportedVersion(2)) { try await store.list() }
    await #expect(throws: CaptureError.unsupportedVersion(2)) {
      try await store.save(text: "Do not downgrade")
    }
    #expect(try Data(contentsOf: fixture.fileURL) == original)
  }

  @Test(arguments: ["", "  ", " untrimmed "])
  func invalidPersistedTextIsRejected(text: String) async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    try fixture.writeRecords([CaptureRecord(text: text)])
    await #expect(throws: CaptureError.corruptData) {
      try await FileCaptureStore(fileURL: fixture.fileURL).list()
    }
  }

  @Test func oversizedPersistedTextIsRejected() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    try fixture.writeRecords([
      CaptureRecord(text: String(repeating: "x", count: FileCaptureStore.maximumTextLength + 1))
    ])
    await #expect(throws: CaptureError.corruptData) {
      try await FileCaptureStore(fileURL: fixture.fileURL).list()
    }
  }

  @Test func duplicateIdentifiersAreRejected() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let record = CaptureRecord(text: "One")
    try fixture.writeRecords([record, record])
    await #expect(throws: CaptureError.corruptData) {
      try await FileCaptureStore(fileURL: fixture.fileURL).list()
    }
  }

  @Test func concurrentSavesDoNotLoseRecords() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = FileCaptureStore(fileURL: fixture.fileURL)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<50 {
        group.addTask { try await store.save(text: "Record \(index)") }
      }
      try await group.waitForAll()
    }
    let records = try await FileCaptureStore(fileURL: fixture.fileURL).list()
    #expect(records.count == 50)
    #expect(Set(records.map(\.text)).count == 50)
    #expect(Set(records.map(\.id)).count == 50)
  }

  @Test(.enabled(if: NSUserName() != "root"))
  func failedWritesPreservePristineData() async throws {
    let fixture = Fixture()
    defer { fixture.cleanUp() }
    let store = FileCaptureStore(fileURL: fixture.fileURL)
    let record = try await store.save(text: "Preserve this record")
    let original = try Data(contentsOf: fixture.fileURL)
    let manager = FileManager.default
    try manager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.fileURL.path)
    try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
    defer {
      try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
      try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.fileURL.path)
    }
    await #expect(throws: (any Error).self) { try await store.save(text: "Must fail") }
    await #expect(throws: (any Error).self) { try await store.delete(id: record.id) }
    #expect(try Data(contentsOf: fixture.fileURL) == original)
    #expect(try await store.list() == [record])
  }

  @Test func nonFileURLIsRejectedWithoutNetworkAccess() async throws {
    let store = FileCaptureStore(fileURL: try #require(URL(string: "https://example.com/data")))
    await #expect(throws: CaptureError.invalidStorageURL) { try await store.list() }
    await #expect(throws: CaptureError.invalidStorageURL) { try await store.save(text: "Idea") }
  }

  private struct Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MunieCoreTests-\(UUID().uuidString)", isDirectory: true)

    var fileURL: URL { directory.appendingPathComponent("captures.json") }

    func write(_ text: String) throws {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(text.utf8).write(to: fileURL)
    }

    func writeRecords(_ records: [CaptureRecord]) throws {
      struct Envelope: Encodable {
        let schemaVersion = 1
        let records: [CaptureRecord]
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONEncoder().encode(Envelope(records: records)).write(to: fileURL)
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
