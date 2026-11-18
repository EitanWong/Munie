#if os(iOS)
  import Foundation
  import Security

  struct RemoteConnectionCredential: Codable, Sendable {
    let endpoint: URL
    let hostID: UUID
    let token: String
  }

  enum RemoteCredentialError: Error {
    case keychain(OSStatus)
    case malformedData, randomFailure
  }

  /// Credentials never migrate or synchronize. A locked device must unlock before connecting.
  actor RemoteCredentialStore {
    private let service = "app.munie.remote.connection"
    private let account = "primary-mac"

    func load() throws -> RemoteConnectionCredential? {
      var query = baseQuery
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess else { throw RemoteCredentialError.keychain(status) }
      guard let data = result as? Data else { throw RemoteCredentialError.malformedData }
      return try JSONDecoder().decode(RemoteConnectionCredential.self, from: data)
    }

    func save(_ credential: RemoteConnectionCredential) throws {
      let data = try JSONEncoder().encode(credential)
      let attributes: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
      let update = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
      if update == errSecItemNotFound {
        let status = SecItemAdd(
          baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw RemoteCredentialError.keychain(status) }
      } else if update != errSecSuccess {
        throw RemoteCredentialError.keychain(update)
      }
    }

    func delete() throws {
      let status = SecItemDelete(baseQuery as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw RemoteCredentialError.keychain(status)
      }
    }

    private var baseQuery: [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false,
      ]
    }

    static func randomSecret() throws -> String {
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw RemoteCredentialError.randomFailure
      }
      return Data(bytes).base64EncodedString()
    }
  }
#endif
