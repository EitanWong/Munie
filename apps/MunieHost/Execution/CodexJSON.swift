import Foundation

/// A JSON value with distinct Boolean, signed integer and floating-point cases.
public enum CodexJSON: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([CodexJSON])
  case object([String: CodexJSON])

  public var object: [String: CodexJSON]? {
    if case .object(let value) = self { value } else { nil }
  }
  public var array: [CodexJSON]? { if case .array(let value) = self { value } else { nil } }
  public var string: String? { if case .string(let value) = self { value } else { nil } }
  public var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
  public var number: Double? { if case .number(let value) = self { value } else { nil } }
  public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let boolean = try? value.decode(Bool.self) {
      self = .bool(boolean)
    } else if let integer = try? value.decode(Int64.self) {
      self = .integer(integer)
    } else if let number = try? value.decode(Double.self), number.isFinite {
      self = .number(number)
    } else if let string = try? value.decode(String.self) {
      self = .string(string)
    } else if let array = try? value.decode([CodexJSON].self) {
      self = .array(array)
    } else {
      self = .object(try value.decode([String: CodexJSON].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null: try value.encodeNil()
    case .bool(let boolean): try value.encode(boolean)
    case .integer(let integer): try value.encode(integer)
    case .number(let number):
      guard number.isFinite else { throw CodexJSONError.invalidValue }
      try value.encode(number)
    case .string(let string): try value.encode(string)
    case .array(let array): try value.encode(array)
    case .object(let object): try value.encode(object)
    }
  }

  /// Wire decoding also rejects duplicate keys, excessive depth and integers outside Int64.
  /// General-purpose Decoder implementations cannot expose duplicate object keys.
  public static func decode(_ data: Data) throws -> CodexJSON {
    guard String(data: data, encoding: .utf8) != nil else { throw CodexJSONError.invalidUTF8 }
    var parser = Parser(bytes: Array(data))
    let result = try parser.value(depth: 0)
    parser.skipWhitespace()
    guard parser.offset == parser.bytes.count else { throw CodexJSONError.invalidValue }
    return result
  }

  public func encoded(maximumBytes: Int = 16_777_216) throws -> Data {
    guard maximumBytes > 0 else { throw CodexJSONError.sizeLimit }
    var result = Data()
    try append(to: &result, depth: 0, maximumBytes: maximumBytes)
    return result
  }

  private func append(to data: inout Data, depth: Int, maximumBytes: Int) throws {
    guard depth <= 64 else { throw CodexJSONError.excessiveDepth }
    guard data.count < maximumBytes else { throw CodexJSONError.sizeLimit }
    switch self {
    case .null: data.append(contentsOf: "null".utf8)
    case .bool(let value): data.append(contentsOf: (value ? "true" : "false").utf8)
    case .integer(let value): data.append(contentsOf: String(value).utf8)
    case .number(let value):
      guard value.isFinite else { throw CodexJSONError.invalidValue }
      // An explicit decimal point preserves the .number case even for an integral Double.
      var text = String(value)
      if !text.contains(".") && !text.lowercased().contains("e") { text += ".0" }
      data.append(contentsOf: text.utf8)
    case .string(let value):
      guard value.utf8.count <= maximumBytes - data.count else { throw CodexJSONError.sizeLimit }
      data.append(try JSONEncoder().encode(value))
    case .array(let values):
      guard values.count <= maximumBytes - data.count else { throw CodexJSONError.sizeLimit }
      data.append(91)
      for (offset, value) in values.enumerated() {
        if offset > 0 { data.append(44) }
        try value.append(to: &data, depth: depth + 1, maximumBytes: maximumBytes)
      }
      data.append(93)
    case .object(let values):
      guard values.count <= (maximumBytes - data.count) / 4 else { throw CodexJSONError.sizeLimit }
      data.append(123)
      for (offset, key) in values.keys.sorted().enumerated() {
        if offset > 0 { data.append(44) }
        guard key.utf8.count <= maximumBytes - data.count else { throw CodexJSONError.sizeLimit }
        data.append(try JSONEncoder().encode(key))
        data.append(58)
        try values[key]?.append(to: &data, depth: depth + 1, maximumBytes: maximumBytes)
      }
      data.append(125)
    }
    guard data.count <= maximumBytes else { throw CodexJSONError.sizeLimit }
  }
}

public enum CodexJSONError: Error, Sendable, Equatable {
  case invalidUTF8, invalidValue, duplicateKey, excessiveDepth, sizeLimit
}

private struct Parser {
  let bytes: [UInt8]
  var offset = 0

  mutating func skipWhitespace() {
    while offset < bytes.count {
      switch bytes[offset] {
      case 9, 10, 13, 32: offset += 1
      default: return
      }
    }
  }

  mutating func value(depth: Int) throws -> CodexJSON {
    guard depth <= 64 else { throw CodexJSONError.excessiveDepth }
    skipWhitespace()
    guard offset < bytes.count else { throw CodexJSONError.invalidValue }
    switch bytes[offset] {
    case 110:
      try literal("null")
      return .null
    case 116:
      try literal("true")
      return .bool(true)
    case 102:
      try literal("false")
      return .bool(false)
    case 34: return .string(try string())
    case 91:
      offset += 1
      skipWhitespace()
      var array: [CodexJSON] = []
      if take(93) { return .array(array) }
      repeat {
        array.append(try value(depth: depth + 1))
        skipWhitespace()
      } while take(44)
      guard take(93) else { throw CodexJSONError.invalidValue }
      return .array(array)
    case 123:
      offset += 1
      skipWhitespace()
      var object: [String: CodexJSON] = [:]
      if take(125) { return .object(object) }
      repeat {
        skipWhitespace()
        let key = try string()
        guard object[key] == nil else { throw CodexJSONError.duplicateKey }
        skipWhitespace()
        guard take(58) else { throw CodexJSONError.invalidValue }
        object[key] = try value(depth: depth + 1)
        skipWhitespace()
      } while take(44)
      guard take(125) else { throw CodexJSONError.invalidValue }
      return .object(object)
    default: return try numberValue()
    }
  }

  mutating func literal(_ text: String) throws {
    let literal = Array(text.utf8)
    guard bytes.count - offset >= literal.count,
      Array(bytes[offset..<(offset + literal.count)]) == literal
    else { throw CodexJSONError.invalidValue }
    offset += literal.count
  }

  mutating func take(_ byte: UInt8) -> Bool {
    guard offset < bytes.count, bytes[offset] == byte else { return false }
    offset += 1
    return true
  }

  mutating func string() throws -> String {
    let start = offset
    guard take(34) else { throw CodexJSONError.invalidValue }
    while offset < bytes.count {
      let byte = bytes[offset]
      offset += 1
      if byte == 34 {
        return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
      }
      guard byte >= 32 else { throw CodexJSONError.invalidValue }
      if byte == 92 {
        guard offset < bytes.count else { throw CodexJSONError.invalidValue }
        offset += 1
      }
    }
    throw CodexJSONError.invalidValue
  }

  mutating func numberValue() throws -> CodexJSON {
    let start = offset
    _ = take(45)
    guard offset < bytes.count else { throw CodexJSONError.invalidValue }
    if !take(48) {
      guard (49...57).contains(bytes[offset]) else { throw CodexJSONError.invalidValue }
      while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
    }
    var floating = false
    if take(46) {
      floating = true
      let digits = offset
      while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
      guard offset > digits else { throw CodexJSONError.invalidValue }
    }
    if take(101) || take(69) {
      floating = true
      if !take(43) { _ = take(45) }
      let digits = offset
      while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
      guard offset > digits else { throw CodexJSONError.invalidValue }
    }
    let text = String(decoding: bytes[start..<offset], as: UTF8.self)
    if !floating {
      guard let integer = Int64(text) else { throw CodexJSONError.invalidValue }
      return .integer(integer)
    }
    guard let number = Double(text), number.isFinite else { throw CodexJSONError.invalidValue }
    return .number(number)
  }
}
