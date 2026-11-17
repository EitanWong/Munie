import Foundation

public struct PendingSubmission: Codable, Equatable, Sendable {
  public let request: RemoteRequest
  public let createdAt: Date
  public let endpoint: URL?

  public init(request: RemoteRequest, createdAt: Date = Date(), endpoint: URL? = nil) {
    self.request = request
    self.createdAt = createdAt
    self.endpoint = endpoint
  }
}

public protocol PendingSubmissionStore: Sendable {
  func load() async throws -> PendingSubmission?
  func save(_ pending: PendingSubmission?) async throws
}

public actor MemoryPendingSubmissionStore: PendingSubmissionStore {
  private var pending: PendingSubmission?
  public init() {}
  public func load() -> PendingSubmission? { pending }
  public func save(_ pending: PendingSubmission?) { self.pending = pending }
}

/// Private per-installation recovery state. It contains the unsent/uncertain prompt, never a token.
public actor FilePendingSubmissionStore: PendingSubmissionStore {
  private let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  public func load() throws -> PendingSubmission? {
    guard fileURL.isFileURL else { throw RemoteClientError.persistence }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      guard let size = attributes[.size] as? NSNumber, size.intValue <= 131_072 else {
        throw RemoteClientError.persistence
      }
      let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
      guard envelope.version == 1, envelope.pending?.request.op == .submit else {
        throw RemoteClientError.persistence
      }
      return envelope.pending
    } catch { throw RemoteClientError.persistence }
  }

  public func save(_ pending: PendingSubmission?) throws {
    guard fileURL.isFileURL else { throw RemoteClientError.persistence }
    do {
      if pending == nil {
        if FileManager.default.fileExists(atPath: fileURL.path) {
          try FileManager.default.removeItem(at: fileURL)
        }
        return
      }
      guard pending?.request.op == .submit else { throw RemoteClientError.persistence }
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let data = try JSONEncoder().encode(Envelope(version: 1, pending: pending))
      guard data.count <= 131_072 else { throw RemoteClientError.persistence }
      #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
      #else
        try data.write(to: fileURL, options: .atomic)
      #endif
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch { throw RemoteClientError.persistence }
  }

  private struct Envelope: Codable {
    let version: Int
    let pending: PendingSubmission?
  }
}
