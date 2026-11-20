import Foundation
import Security

struct DesktopOpenAIKey: Sendable, Equatable {
  let value: String

  init?(validating value: String) {
    guard (1...512).contains(value.utf8.count),
      value.utf8.allSatisfy({ (0x21...0x7e).contains($0) })
    else { return nil }
    self.value = value
  }
}

protocol DesktopOpenAIKeyStore: Sendable {
  func read() async throws -> DesktopOpenAIKey?
  func save(_ key: DesktopOpenAIKey) async throws
  func remove() async throws
}

enum DesktopOpenAIKeyStoreFailure: Error {
  case unavailable
}

/// Uses the per-user macOS Keychain. This app does not opt into the
/// Data Protection Keychain or iCloud synchronization.
actor DesktopKeychainOpenAIKeyStore: DesktopOpenAIKeyStore {
  private var item: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "app.munie.desktop.openai",
      kSecAttrAccount as String: "model-api-key",
    ]
  }

  func read() async throws -> DesktopOpenAIKey? {
    var query = item
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, data.count <= 512,
      let value = String(data: data, encoding: .utf8),
      let key = DesktopOpenAIKey(validating: value)
    else { throw DesktopOpenAIKeyStoreFailure.unavailable }
    return key
  }

  func save(_ key: DesktopOpenAIKey) async throws {
    let attributes = [kSecValueData as String: Data(key.value.utf8)]
    let update = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw DesktopOpenAIKeyStoreFailure.unavailable }
    let newItem = item.merging(attributes) { _, value in value }
    let add = SecItemAdd(newItem as CFDictionary, nil)
    if add == errSecDuplicateItem,
      SecItemUpdate(item as CFDictionary, attributes as CFDictionary) == errSecSuccess
    {
      return
    }
    guard add == errSecSuccess else { throw DesktopOpenAIKeyStoreFailure.unavailable }
  }

  func remove() async throws {
    let status = SecItemDelete(item as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound
    else { throw DesktopOpenAIKeyStoreFailure.unavailable }
  }
}
