import Foundation
import Security

struct DesktopProviderKey: Sendable, Equatable {
  let value: String

  init?(validating value: String) {
    guard (1...512).contains(value.utf8.count),
      value.utf8.allSatisfy({ (0x21...0x7e).contains($0) })
    else { return nil }
    self.value = value
  }
}

struct DesktopCustomProvider: Sendable, Equatable {
  let baseURL: String
  let model: String
  let apiKey: DesktopProviderKey

  init?(baseURL: String, model: String, apiKey: DesktopProviderKey) {
    guard Self.isValidBaseURL(baseURL), Self.isValidModel(model) else { return nil }
    self.baseURL = baseURL
    self.model = model
    self.apiKey = apiKey
  }

  static func isValidBaseURL(_ value: String) -> Bool {
    guard value.utf8.count <= 2048, value.lowercased().hasPrefix("https://"),
      value.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
      !value.contains("\\"), !value.contains("%"),
      let components = URLComponents(string: value),
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.port.map({ (1...65_535).contains($0) }) ?? true
    else { return false }
    let dotted = host.split(separator: ".", omittingEmptySubsequences: false)
    let numeric = dotted.allSatisfy { part in
      let lower = part.lowercased()
      return !part.isEmpty
        && (part.utf8.allSatisfy { (0x30...0x39).contains($0) } || lower.hasPrefix("0x"))
    }
    if numeric {
      guard dotted.count == 4,
        dotted.allSatisfy({ part in
          guard let byte = UInt8(part) else { return false }
          return String(byte) == part
        })
      else { return false }
    }
    let path = components.percentEncodedPath
    return !path.contains("//")
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
        segment != "." && segment != ".."
          && segment.utf8.allSatisfy { byte in
            isASCIIAlphanumeric(byte) || [0x2d, 0x2e, 0x5f, 0x7e].contains(byte)
          }
      }
  }

  static func responsesEndpoint(_ baseURL: String) -> String {
    (baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL) + "/responses"
  }

  static func isValidModel(_ value: String) -> Bool {
    (1...128).contains(value.utf8.count)
      && value.utf8.allSatisfy { byte in
        isASCIIAlphanumeric(byte) || [0x2d, 0x2e, 0x2f, 0x3a, 0x5f].contains(byte)
      }
  }

  private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
  }
}

enum DesktopProviderCredentials: Sendable, Equatable {
  case openAI(DesktopProviderKey)
  case custom(DesktopCustomProvider)

  var startParameters: DesktopJSON {
    switch self {
    case .openAI(let key):
      .object(["apiKey": .string(key.value)])
    case .custom(let profile):
      .object([
        "customProvider": .object([
          "baseURL": .string(profile.baseURL), "model": .string(profile.model),
          "apiKey": .string(profile.apiKey.value),
        ])
      ])
    }
  }
}

protocol DesktopProviderStore: Sendable {
  func read() async throws -> DesktopProviderCredentials?
  func save(_ credentials: DesktopProviderCredentials) async throws
  func remove() async throws
}

enum DesktopProviderStoreFailure: Error {
  case unavailable
}

enum DesktopProviderRecord {
  private struct CustomRecord: Codable {
    let baseURL: String
    let model: String
    let apiKey: String
  }

  // The leading NUL cannot occur in a legacy plaintext OpenAI key.
  private static let customVersion = Data([0, 1])

  static func encode(_ credentials: DesktopProviderCredentials) throws -> Data {
    switch credentials {
    case .openAI(let key):
      return Data(key.value.utf8)
    case .custom(let profile):
      let record = CustomRecord(
        baseURL: profile.baseURL, model: profile.model, apiKey: profile.apiKey.value)
      return customVersion + (try JSONEncoder().encode(record))
    }
  }

  static func decode(_ data: Data) throws -> DesktopProviderCredentials {
    guard data.count <= 8192 else { throw DesktopProviderStoreFailure.unavailable }
    if data.starts(with: customVersion) {
      guard
        let record = try? JSONDecoder().decode(CustomRecord.self, from: data.dropFirst(2)),
        let key = DesktopProviderKey(validating: record.apiKey),
        let profile = DesktopCustomProvider(
          baseURL: record.baseURL, model: record.model, apiKey: key)
      else { throw DesktopProviderStoreFailure.unavailable }
      return .custom(profile)
    }
    guard let value = String(data: data, encoding: .utf8),
      let key = DesktopProviderKey(validating: value)
    else { throw DesktopProviderStoreFailure.unavailable }
    return .openAI(key)
  }
}

/// Uses the per-user macOS Keychain. This app does not opt into the
/// Data Protection Keychain or iCloud synchronization.
actor DesktopKeychainProviderStore: DesktopProviderStore {
  private var item: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "app.munie.desktop.openai",
      kSecAttrAccount as String: "model-api-key",
    ]
  }

  func read() async throws -> DesktopProviderCredentials? {
    var query = item
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data
    else { throw DesktopProviderStoreFailure.unavailable }
    return try DesktopProviderRecord.decode(data)
  }

  func save(_ credentials: DesktopProviderCredentials) async throws {
    let attributes = [kSecValueData as String: try DesktopProviderRecord.encode(credentials)]
    let update = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw DesktopProviderStoreFailure.unavailable }
    let newItem = item.merging(attributes) { _, value in value }
    let add = SecItemAdd(newItem as CFDictionary, nil)
    if add == errSecDuplicateItem,
      SecItemUpdate(item as CFDictionary, attributes as CFDictionary) == errSecSuccess
    {
      return
    }
    guard add == errSecSuccess else { throw DesktopProviderStoreFailure.unavailable }
  }

  func remove() async throws {
    let status = SecItemDelete(item as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound
    else { throw DesktopProviderStoreFailure.unavailable }
  }
}
