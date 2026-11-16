import Foundation
import MunieCore
import Testing

@testable import Munie

@MainActor
struct CaptureModelTests {
  @Test func successfulSaveClearsDraftAndUpdatesList() async {
    let model = CaptureModel(store: StubStore())
    await model.load()
    model.draft = "Remember the idea"
    #expect(await model.save())
    #expect(model.draft.isEmpty)
    #expect(model.records.map(\.text) == ["Remember the idea"])
  }

  @Test func failedSavePreservesDraftAndReportsFailure() async {
    let model = CaptureModel(store: StubStore(failSave: true))
    await model.load()
    model.draft = "Keep this draft"
    #expect(await model.save() == false)
    #expect(model.draft == "Keep this draft")
    #expect(model.records.isEmpty)
    #expect(model.errorMessage != nil)
    #expect(!model.isBusy)
  }

  @Test func loadFailurePreventsOverwritingUnreadData() async {
    let model = CaptureModel(store: StubStore(failLoad: true))
    await model.load()
    model.draft = "Do not overwrite"
    #expect(!model.hasLoaded)
    #expect(!model.canSave)
    #expect(await model.save() == false)
    #expect(model.errorMessage != nil)
  }

  @Test func failedDeleteKeepsVisibleRecord() async throws {
    let model = CaptureModel(store: StubStore(failDelete: true))
    await model.load()
    model.draft = "Still here"
    _ = await model.save()
    let record = try #require(model.records.first)
    await model.delete(record)
    #expect(model.records == [record])
    #expect(model.errorMessage != nil)
  }

  @Test func searchAndInputLimits() async {
    let model = CaptureModel(store: StubStore())
    await model.load()
    model.draft = "Travel tomorrow"
    _ = await model.save()
    model.search = " TRAVEL "
    #expect(model.filteredRecords.count == 1)
    model.search = "missing"
    #expect(model.filteredRecords.isEmpty)
    model.draft = " \n "
    #expect(!model.canSave)
    model.draft = String(repeating: "a", count: 10_001)
    #expect(!model.canSave)
  }

  @Test func inFlightEditsArePreserved() async {
    let store = SuspendedStore()
    let model = CaptureModel(store: store)
    await model.load()
    model.draft = "Submitted"
    let saving = Task { await model.save() }
    await store.waitUntilSaving()
    model.draft = "New unsaved thought"
    await store.releaseSave()
    #expect(await saving.value)
    #expect(model.records.map(\.text) == ["Submitted"])
    #expect(model.draft == "New unsaved thought")
  }
}

private actor SuspendedStore: CaptureStore {
  private var hasStarted = false
  private var started: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?

  func list() -> [CaptureRecord] { [] }

  func save(text: String) async -> CaptureRecord {
    await withCheckedContinuation { continuation in
      release = continuation
      hasStarted = true
      started?.resume()
      started = nil
    }
    return CaptureRecord(text: text)
  }

  func delete(id: UUID) {}

  func waitUntilSaving() async {
    if hasStarted { return }
    await withCheckedContinuation { started = $0 }
  }

  func releaseSave() {
    release?.resume()
    release = nil
  }
}

private actor StubStore: CaptureStore {
  let failSave: Bool
  let failLoad: Bool
  let failDelete: Bool
  private var records: [CaptureRecord] = []

  init(failSave: Bool = false, failLoad: Bool = false, failDelete: Bool = false) {
    self.failSave = failSave
    self.failLoad = failLoad
    self.failDelete = failDelete
  }

  func list() throws -> [CaptureRecord] {
    if failLoad { throw CaptureError.corruptData }
    return records
  }

  func save(text: String) throws -> CaptureRecord {
    if failSave { throw CocoaError(.fileWriteOutOfSpace) }
    let record = CaptureRecord(id: UUID(), text: text, createdAt: Date())
    records.insert(record, at: 0)
    return record
  }

  func delete(id: UUID) throws {
    if failDelete { throw CocoaError(.fileWriteNoPermission) }
    records.removeAll { $0.id == id }
  }
}
