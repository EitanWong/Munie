import Foundation
import Testing

@testable import MunieRemote

struct TransportAndStorageTests {
  @Test(arguments: [
    "http://example.com", "https://user:password@example.com", "https://example.com?token=secret",
    "https://example.com/#fragment", "https://example.com/other", "file:///fixture",
  ])
  func untrustedEndpointRejected(value: String) {
    #expect(throws: RemoteClientError.invalidEndpoint) {
      try RemoteHTTPClient(endpoint: URL(string: value)!)
    }
  }

  @Test func exactOriginNormalizationAndExplicitLoopbackOnly() throws {
    let origin = try RemoteHTTPClient.validatedEndpoint(URL(string: "https://mac.example:8443/")!)
    #expect(origin.absoluteString == "https://mac.example:8443/v1")
    #expect(throws: RemoteClientError.invalidEndpoint) {
      try RemoteHTTPClient.validatedEndpoint(URL(string: "http://127.0.0.1:8888")!)
    }
    #expect(throws: RemoteClientError.invalidEndpoint) {
      try RemoteHTTPClient.validatedEndpoint(
        URL(string: "http://192.168.1.2:8888")!, allowsLoopbackHTTP: true)
    }
    let loopback = try RemoteHTTPClient.validatedEndpoint(
      URL(string: "http://127.0.0.1:8888")!, allowsLoopbackHTTP: true)
    #expect(loopback.absoluteString == "http://127.0.0.1:8888/v1")
  }

  @Test(arguments: [
    "short", String(repeating: "x", count: 513),
    String(repeating: "x", count: 32) + "\r\nInjected: yes",
  ])
  func credentialRejectsHeaderInjection(value: String) {
    #expect(throws: RemoteClientError.invalidCredential) {
      try RemoteHTTPClient(endpoint: URL(string: "https://mac.example")!, credential: value)
    }
  }

  @Test func pendingRequestSurvivesRelaunchWithoutCredential() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "pending.json")
    let request = RemoteRequest(
      op: .submit, requestID: UUID(), projectID: UUID(), text: "你好 marker")
    let pending = PendingSubmission(
      request: request, endpoint: URL(string: "https://mac.example/v1"))
    let first = FilePendingSubmissionStore(fileURL: file)
    try await first.save(pending)
    let reopened = FilePendingSubmissionStore(fileURL: file)
    #expect(try await reopened.load() == pending)
    let json = try String(contentsOf: file, encoding: .utf8)
    #expect(!json.contains("credential"))
    #expect(!json.contains("Authorization"))
    let mode =
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    try await reopened.save(nil)
    #expect(try await first.load() == nil)
  }

  @Test func corruptPendingStateIsNotReset() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "pending.json")
    let corrupt = Data("{\"version\":99,\"pending\":null}".utf8)
    try corrupt.write(to: file)
    let store = FilePendingSubmissionStore(fileURL: file)
    await #expect(throws: RemoteClientError.persistence) { try await store.load() }
    #expect(try Data(contentsOf: file) == corrupt)
  }
}
