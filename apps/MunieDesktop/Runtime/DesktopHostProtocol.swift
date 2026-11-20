import Foundation

/// The private Mac protocol carries state and pairing data. Only the start request may carry an API key.
enum DesktopJSON: Codable, Equatable, Sendable {
  case object([String: DesktopJSON])
  case array([DesktopJSON])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let boolean = try? value.decode(Bool.self) {
      self = .bool(boolean)
    } else if let string = try? value.decode(String.self) {
      self = .string(string)
    } else if let number = try? value.decode(Double.self), number.isFinite {
      self = .number(number)
    } else if let array = try? value.decode([DesktopJSON].self) {
      self = .array(array)
    } else {
      self = .object(try value.decode([String: DesktopJSON].self))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .object(let object): try value.encode(object)
    case .array(let array): try value.encode(array)
    case .string(let string): try value.encode(string)
    case .number(let number): try value.encode(number)
    case .bool(let boolean): try value.encode(boolean)
    case .null: try value.encodeNil()
    }
  }

  subscript(_ key: String) -> DesktopJSON? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }

  var string: String? {
    guard case .string(let string) = self else { return nil }
    return string
  }

  var boolean: Bool? {
    guard case .bool(let boolean) = self else { return nil }
    return boolean
  }

  var array: [DesktopJSON]? {
    guard case .array(let array) = self else { return nil }
    return array
  }
}

struct DesktopHostRequest: Encodable, Sendable {
  let v = 1
  let id: String
  let method: String
  let params: DesktopJSON
}

struct DesktopHostEnvelope: Decodable, Sendable {
  let v: Int
  let id: String?
  let result: DesktopJSON?
  let error: DesktopHostControlError?
  let event: String?
  let data: DesktopJSON?

  static func decode(_ data: Data) throws -> Self {
    let result = try JSONDecoder().decode(Self.self, from: data)
    guard result.v == 1 else { throw DesktopHostFailure.invalidProtocol }
    if result.id != nil {
      guard result.event == nil, (result.result != nil) != (result.error != nil) else {
        throw DesktopHostFailure.invalidProtocol
      }
    } else {
      guard result.event != nil, result.result == nil, result.error == nil else {
        throw DesktopHostFailure.invalidProtocol
      }
    }
    return result
  }
}

struct DesktopHostControlError: Decodable, Error, Sendable {
  let code: String
  // Intentionally never surfaced verbatim: runtime messages can contain private paths or data.
  let message: String?
}

enum DesktopHostEvent: Sendable {
  case message(name: String, data: DesktopJSON)
  case exited(status: Int32)
  case protocolFailure
}

enum DesktopHostFailure: Error, Equatable {
  case resourcesUnavailable
  case alreadyRunning
  case notRunning
  case invalidProtocol
  case oversizedFrame
  case tooManyRequests
  case timedOut
  case writeFailed
  case helperExited
  case cleanupUnconfirmed
  case loginURLRejected
}

struct DesktopProcessOwnership: Codable, Equatable, Sendable {
  let ownerPid: Int32
  let groupId: Int32

  init?(status: DesktopJSON, expectedOwner: Int32) {
    guard let owner = status["ownership"]?["ownerPid"],
      let group = status["ownership"]?["groupId"],
      case .number(let ownerNumber) = owner, case .number(let groupNumber) = group,
      let ownerPid = Int32(exactly: ownerNumber), let groupId = Int32(exactly: groupNumber),
      ownerPid == expectedOwner, ownerPid > 1, groupId > 1
    else { return nil }
    self.ownerPid = ownerPid
    self.groupId = groupId
  }
}

/// Both the live helper and lifecycle fixtures use the same small boundary.
protocol DesktopHostRuntime: Sendable {
  func launch() async throws -> AsyncStream<DesktopHostEvent>
  func request(_ method: String, params: DesktopJSON) async throws -> DesktopJSON
  func shutdown() async throws
}

/// Counts UTF-8 bytes before decoding or accumulating a complete JSON line.
struct DesktopHostLineBuffer: Sendable {
  static let maximumBytes = 1_048_576
  private var pending = Data()

  mutating func append(_ byte: UInt8) throws -> Data? {
    if byte == 10 {
      guard !pending.isEmpty else { throw DesktopHostFailure.invalidProtocol }
      let complete = pending
      pending.removeAll(keepingCapacity: true)
      return complete
    }
    guard pending.count < Self.maximumBytes else { throw DesktopHostFailure.oversizedFrame }
    pending.append(byte)
    return nil
  }

  func finish() throws {
    guard pending.isEmpty else { throw DesktopHostFailure.invalidProtocol }
  }
}

enum DesktopLoginURL {
  /// Only the native account service may supply an OpenAI HTTPS authorization URL.
  static func validated(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.scheme == "https",
      let host = url.host?.lowercased(),
      host == "auth.openai.com" || host == "auth0.openai.com" || host == "chatgpt.com",
      url.user == nil, url.password == nil, url.port == nil || url.port == 443
    else { throw DesktopHostFailure.loginURLRejected }
    return url
  }
}
