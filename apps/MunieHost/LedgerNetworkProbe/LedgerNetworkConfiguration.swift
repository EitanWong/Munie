import Darwin
import Foundation
import MunieExecutionHost
import SQLite3

enum LedgerNetworkProbeFailure: Error {
  case invalidConfiguration, invalidRequest, framing, responseLimit
}

/// Trusted, temporary fixture enrollment. This is not a pairing or certificate rotation service.
struct LedgerNetworkConfiguration: Sendable {
  struct Device: Sendable {
    let fingerprint: String
    let id: UUID
    let projects: Set<UUID>
  }

  static let maximumConfigBytes = 32_768
  let root: URL
  let initialize: Bool
  let hostID: UUID
  let projects: [UUID]
  let devices: [Device]

  var stateDirectory: URL { root.appendingPathComponent("state", isDirectory: true) }

  func projectDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(id.uuidString, isDirectory: true)
  }

  static func load(path: String) throws -> Self {
    let url = URL(fileURLWithPath: path)
    guard path.hasPrefix("/"), path == url.path else {
      throw LedgerNetworkProbeFailure.invalidConfiguration
    }
    try validatePrivateFile(url, minimumBytes: 1, maximumBytes: maximumConfigBytes)
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    let data = try input.read(upToCount: maximumConfigBytes + 1) ?? Data()
    return try decode(data)
  }

  static func decode(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= maximumConfigBytes,
      let value = try CodexJSON.decode(data).object,
      Set(value.keys) == ["rootDirectory", "initialize", "hostID", "projects", "devices"],
      let rootPath = value["rootDirectory"]?.string,
      rootPath.hasPrefix("/"), rootPath.utf8.count <= 4096, !rootPath.utf8.contains(0),
      let initialize = value["initialize"]?.bool,
      let projectValues = value["projects"]?.array, (1...16).contains(projectValues.count),
      let deviceValues = value["devices"]?.array, (1...16).contains(deviceValues.count)
    else { throw LedgerNetworkProbeFailure.invalidConfiguration }
    let hostID = try canonicalID(value["hostID"])
    let projects = try projectValues.map { try canonicalID($0) }
    guard Set(projects).count == projects.count else {
      throw LedgerNetworkProbeFailure.invalidConfiguration
    }
    var deviceIDs = Set<UUID>()
    var fingerprints = Set<String>()
    let devices = try deviceValues.map { value -> Device in
      guard let fields = value.object,
        Set(fields.keys) == ["fingerprint", "deviceID", "projectIDs"],
        let fingerprint = fields["fingerprint"]?.string,
        isFingerprint(fingerprint), fingerprints.insert(fingerprint).inserted,
        let grantValues = fields["projectIDs"]?.array, (1...16).contains(grantValues.count)
      else { throw LedgerNetworkProbeFailure.invalidConfiguration }
      let id = try canonicalID(fields["deviceID"])
      let grants = try grantValues.map { try canonicalID($0) }
      guard deviceIDs.insert(id).inserted, Set(grants).count == grants.count,
        Set(grants).isSubset(of: Set(projects))
      else { throw LedgerNetworkProbeFailure.invalidConfiguration }
      return Device(fingerprint: fingerprint, id: id, projects: Set(grants))
    }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    guard root.path == rootPath else { throw LedgerNetworkProbeFailure.invalidConfiguration }
    return Self(
      root: root, initialize: initialize,
      hostID: hostID, projects: projects, devices: devices)
  }

  func validateDirectories() throws {
    try Self.validatePrivateDirectory(root)
    try Self.validatePrivateDirectory(root.appendingPathComponent("projects", isDirectory: true))
    for project in projects { try Self.validatePrivateDirectory(projectDirectory(project)) }
    var information = stat()
    if initialize {
      if lstat(stateDirectory.path, &information) == 0 {
        try Self.validatePrivateDirectory(stateDirectory)
        guard try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path).isEmpty
        else {
          throw LedgerNetworkProbeFailure.invalidConfiguration
        }
      } else if errno != ENOENT {
        throw LedgerNetworkProbeFailure.invalidConfiguration
      }
    } else {
      // Opening a missing store would otherwise initialize a new ledger, which is not resume.
      try Self.validatePrivateDirectory(stateDirectory)
      try Self.validatePrivateFile(
        stateDirectory.appendingPathComponent("submissions.sqlite3"), minimumBytes: 1,
        maximumBytes: 64 * 1024 * 1024)
      try Self.validatePrivateFile(
        stateDirectory.appendingPathComponent(".owner"), minimumBytes: 0, maximumBytes: 0)
      try validateExistingSchema()
    }
  }

  private func validateExistingSchema() throws {
    // HostSubmissionLedger deliberately initializes schema0 stores. Resume must reject those
    // before handing ownership to it, even when a nonempty SQLite file already exists.
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_PRIVATECACHE
    let status = sqlite3_open_v2(
      stateDirectory.appendingPathComponent("submissions.sqlite3").path, &database, flags, nil)
    defer { sqlite3_close(database) }
    guard status == SQLITE_OK else { throw LedgerNetworkProbeFailure.invalidConfiguration }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK
    else {
      throw LedgerNetworkProbeFailure.invalidConfiguration
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
      sqlite3_column_int64(statement, 0) == 1,
      sqlite3_step(statement) == SQLITE_DONE
    else { throw LedgerNetworkProbeFailure.invalidConfiguration }
  }

  static func canonicalID(_ value: CodexJSON?) throws -> UUID {
    guard let raw = value?.string, let id = UUID(uuidString: raw), raw == id.uuidString else {
      throw LedgerNetworkProbeFailure.invalidRequest
    }
    return id
  }

  static func isFingerprint(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func validatePrivateDirectory(_ url: URL) throws {
    var information = stat()
    guard canonicalPath(url.path) == url.path, lstat(url.path, &information) == 0,
      information.st_mode & S_IFMT == S_IFDIR,
      information.st_mode & 0o777 == 0o700, information.st_uid == geteuid()
    else { throw LedgerNetworkProbeFailure.invalidConfiguration }
  }

  private static func validatePrivateFile(_ url: URL, minimumBytes: Int, maximumBytes: Int) throws {
    var information = stat()
    guard url.path.hasPrefix("/"), canonicalPath(url.path) == url.path,
      lstat(url.path, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
      information.st_mode & 0o777 == 0o600, information.st_uid == geteuid(),
      information.st_nlink == 1, information.st_size >= minimumBytes,
      information.st_size <= maximumBytes
    else { throw LedgerNetworkProbeFailure.invalidConfiguration }
  }

  private static func canonicalPath(_ path: String) -> String? {
    guard let pointer = realpath(path, nil) else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
  }
}
