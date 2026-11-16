import Foundation
import MunieCore
import Observation

@MainActor
@Observable
final class CaptureModel {
  private(set) var records: [CaptureRecord] = []
  private(set) var isBusy = false
  private(set) var hasLoaded = false
  var draft = ""
  var search = ""
  var errorMessage: String?
  private let store: any CaptureStore

  init(store: any CaptureStore) {
    self.store = store
  }

  var filteredRecords: [CaptureRecord] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty
      ? records : records.filter { $0.text.localizedStandardContains(query) }
  }

  var canSave: Bool {
    !isBusy && hasLoaded && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && draft.count <= FileCaptureStore.maximumTextLength
  }

  func load() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      records = try await store.list()
      hasLoaded = true
    } catch {
      errorMessage = message(for: error)
    }
  }

  @discardableResult
  func save() async -> Bool {
    guard canSave else { return false }
    isBusy = true
    defer { isBusy = false }
    do {
      let submittedText = draft
      let record = try await store.save(text: submittedText)
      records.insert(record, at: 0)
      if draft == submittedText { draft = "" }
      return true
    } catch {
      errorMessage = message(for: error)
      return false
    }
  }

  func delete(_ record: CaptureRecord) async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await store.delete(id: record.id)
      records.removeAll { $0.id == record.id }
    } catch {
      errorMessage = message(for: error)
    }
  }

  private func message(for error: Error) -> String {
    if let captureError = error as? CaptureError {
      switch captureError {
      case .blankText:
        return String(localized: "Write something before saving.")
      case .textTooLong:
        return String(localized: "Keep each capture within 10,000 characters.")
      case .corruptData, .unsupportedVersion:
        return String(localized: "The saved data could not be read. It has not been overwritten.")
      case .recordNotFound:
        return String(localized: "This capture no longer exists. Reload your captures.")
      case .invalidStorageURL:
        return String(localized: "Munie could not open local storage. Reopen the app to try again.")
      }
    }
    return String(
      localized: "The storage operation failed. Your draft is still available. Try again.")
  }
}
