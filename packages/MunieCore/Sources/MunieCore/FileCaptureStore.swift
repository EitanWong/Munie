import Foundation

/// Own one instance per storage file and share it across callers.
///
/// The actor serializes read/modify/write operations in one process. Independent
/// instances or processes writing the same file require external coordination.
/// Writes are atomic and storage failures never replace the last readable data.
public actor FileCaptureStore: CaptureStore {
  /// Maximum extended grapheme clusters after trimming surrounding whitespace.
  public static let maximumTextLength = 10_000

  private let fileURL: URL
  private let schemaVersion = 1

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func list() async throws -> [CaptureRecord] {
    try load().sorted {
      if $0.createdAt == $1.createdAt {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.createdAt > $1.createdAt
    }
  }

  @discardableResult
  public func save(text: String) async throws -> CaptureRecord {
    let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    try validate(normalizedText)
    var records = try load()
    let record = CaptureRecord(text: normalizedText)
    records.append(record)
    try persist(records)
    return record
  }

  public func delete(id: UUID) async throws {
    var records = try load()
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw CaptureError.recordNotFound(id)
    }
    records.remove(at: index)
    try persist(records)
  }

  private func validate(_ text: String) throws {
    guard !text.isEmpty else { throw CaptureError.blankText }
    guard text.count <= Self.maximumTextLength else {
      throw CaptureError.textTooLong(maximum: Self.maximumTextLength)
    }
  }

  private func load() throws -> [CaptureRecord] {
    guard fileURL.isFileURL else { throw CaptureError.invalidStorageURL }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch CocoaError.fileReadNoSuchFile {
      return []
    }

    let envelope: Envelope
    do {
      let decoder = JSONDecoder()
      let header = try decoder.decode(Header.self, from: data)
      guard header.schemaVersion == schemaVersion else {
        throw CaptureError.unsupportedVersion(header.schemaVersion)
      }
      envelope = try decoder.decode(Envelope.self, from: data)
    } catch let error as CaptureError {
      throw error
    } catch {
      throw CaptureError.corruptData
    }
    let ids = Set(envelope.records.map(\.id))
    guard ids.count == envelope.records.count else { throw CaptureError.corruptData }
    for record in envelope.records {
      let trimmed = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed == record.text else { throw CaptureError.corruptData }
      do {
        try validate(record.text)
      } catch {
        throw CaptureError.corruptData
      }
    }
    return envelope.records
  }

  private func persist(_ records: [CaptureRecord]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Envelope(schemaVersion: schemaVersion, records: records))
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: fileURL, options: .atomic)
  }

  private struct Header: Decodable {
    let schemaVersion: Int
  }

  private struct Envelope: Codable {
    let schemaVersion: Int
    let records: [CaptureRecord]
  }
}
