import Foundation

/// A locally saved thought. Saving does not imply submission to an AI service.
public struct CaptureRecord: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let text: String
  public let createdAt: Date

  public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
  }
}
