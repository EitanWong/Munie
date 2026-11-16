import Foundation

public protocol CaptureStore: Sendable {
  /// Returns saved records, newest first.
  func list() async throws -> [CaptureRecord]

  /// Trims edge whitespace, validates the text and saves it durably.
  @discardableResult
  func save(text: String) async throws -> CaptureRecord

  func delete(id: UUID) async throws
}

public enum CaptureError: Error, Equatable, Sendable {
  case blankText
  case textTooLong(maximum: Int)
  case corruptData
  case unsupportedVersion(Int)
  case recordNotFound(UUID)
  case invalidStorageURL
}
