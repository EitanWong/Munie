import Darwin
import Foundation
import SQLite3

/// Only its owning host actor may access this connection; it deliberately is not Sendable.
final class SQLiteStorage {
  private static let maximumBytes: Int64 = 64 * 1_024 * 1_024
  private static let maximumRows = 10_000
  private let directoryURL: URL
  private var directoryDescriptor: Int32 = -1
  private var ownerDescriptor: Int32 = -1
  private var ownsFileLock = false
  private var databaseDescriptor: Int32 = -1
  private var database: OpaquePointer?

  var changes: Int {
    guard let database else { return 0 }
    return Int(sqlite3_changes(database))
  }
  var sqliteVersion: String { String(cString: sqlite3_libversion()) }

  init(directoryURL: URL) throws {
    self.directoryURL = directoryURL
    do {
      try openDirectory()
      ownerDescriptor = try openPrivateFile(".owner")
      guard flock(ownerDescriptor, LOCK_EX | LOCK_NB) == 0 else {
        if errno == EWOULDBLOCK || errno == EAGAIN { throw SubmissionError.storeBusy }
        throw SubmissionError.invalidStorage
      }
      ownsFileLock = true
      databaseDescriptor = try openPrivateFile("submissions.sqlite3")
      try validateSidecars()
      try validatePaths()
      let result = sqlite3_open_v2(
        directoryURL.appendingPathComponent("submissions.sqlite3").path, &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_NOMUTEX
          | SQLITE_OPEN_PRIVATECACHE,
        nil)
      try check(result)
      try check(sqlite3_busy_timeout(database, 250))
      sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 1_048_576)
      sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 65_536)
      sqlite3_limit(database, SQLITE_LIMIT_VARIABLE_NUMBER, 100)
      try run("PRAGMA trusted_schema = OFF")
      try run("PRAGMA foreign_keys = ON")
      guard try rows("PRAGMA journal_mode = DELETE") == [[.text("delete")]] else {
        throw SubmissionError.invalidStorage
      }
      try run("PRAGMA synchronous = EXTRA")
      try run("PRAGMA fullfsync = ON")
      for (pragma, expected) in [
        ("trusted_schema", Int64(0)), ("foreign_keys", 1), ("synchronous", 3),
        ("fullfsync", 1), ("busy_timeout", 250),
      ] {
        guard try rows("PRAGMA \(pragma)") == [[.integer(expected)]] else {
          throw SubmissionError.invalidStorage
        }
      }
      guard case .integer(let pageSize) = try rows("PRAGMA page_size").first?.first,
        pageSize > 0
      else { throw SubmissionError.invalidStorage }
      let maximumPages = Self.maximumBytes / pageSize
      guard try rows("PRAGMA max_page_count = \(maximumPages)") == [[.integer(maximumPages)]] else {
        throw SubmissionError.invalidStorage
      }
      try validatePaths()
    } catch {
      closeResources()
      throw error
    }
  }

  deinit { closeResources() }

  func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
    _ = try execute(sql, bindings, retainRows: false)
  }

  func rows(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
    try execute(sql, bindings, retainRows: true)
  }

  func transaction<T>(_ body: (SQLiteStorage) throws -> T) throws -> T {
    guard let database, sqlite3_get_autocommit(database) != 0 else {
      throw SubmissionError.storageFailure(code: SQLITE_MISUSE)
    }
    do {
      try run("BEGIN IMMEDIATE")
      guard sqlite3_get_autocommit(database) == 0 else {
        throw SubmissionError.storageFailure(code: SQLITE_MISUSE)
      }
      let result = try body(self)
      try run("COMMIT")
      guard sqlite3_get_autocommit(database) != 0 else {
        throw SubmissionError.storageFailure(code: SQLITE_MISUSE)
      }
      return result
    } catch {
      // SQLite can already have rolled back a FULL/IO error. Preserve the original failure.
      if let database = self.database, sqlite3_get_autocommit(database) == 0 {
        do { try run("ROLLBACK") } catch { closeResources() }
        if let database = self.database, sqlite3_get_autocommit(database) == 0 { closeResources() }
      }
      throw error
    }
  }

  private func execute(_ sql: String, _ bindings: [SQLiteValue], retainRows: Bool) throws
    -> [[SQLiteValue]]
  {
    guard let database else { throw SubmissionError.storageFailure(code: SQLITE_MISUSE) }
    try validatePaths()
    guard !sql.utf8.contains(0), sql.utf8.count <= 65_536 else {
      throw SubmissionError.storageFailure(code: SQLITE_MISUSE)
    }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    try sql.withCString { pointer in
      var tail: UnsafePointer<CChar>?
      try check(sqlite3_prepare_v2(database, pointer, -1, &statement, &tail))
      guard statement != nil, let tail,
        String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw SubmissionError.storageFailure(code: SQLITE_MISUSE) }
    }
    guard sqlite3_bind_parameter_count(statement) == bindings.count else {
      throw SubmissionError.storageFailure(code: SQLITE_RANGE)
    }
    for (offset, value) in bindings.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .null:
        try check(sqlite3_bind_null(statement, index))
      case .integer(let integer):
        try check(sqlite3_bind_int64(statement, index, integer))
      case .text(let text):
        let byteCount = text.utf8.count
        guard byteCount <= 1_048_576 else {
          throw SubmissionError.storageFailure(code: SQLITE_TOOBIG)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try text.withCString { pointer in
          try check(sqlite3_bind_text(statement, index, pointer, Int32(byteCount), transient))
        }
      }
    }
    var result: [[SQLiteValue]] = []
    var count = 0
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else { throw SubmissionError.storageFailure(code: status) }
      count += 1
      guard count <= Self.maximumRows else {
        throw SubmissionError.storageFailure(code: SQLITE_TOOBIG)
      }
      if retainRows {
        var row: [SQLiteValue] = []
        for index in 0..<sqlite3_column_count(statement) {
          switch sqlite3_column_type(statement, index) {
          case SQLITE_NULL: row.append(.null)
          case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
          case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let pointer = sqlite3_column_text(statement, index),
              let text = String(
                bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8)
            else { throw SubmissionError.storageFailure(code: SQLITE_MISMATCH) }
            row.append(.text(text))
          default: throw SubmissionError.storageFailure(code: SQLITE_MISMATCH)
          }
        }
        result.append(row)
      }
    }
    try validatePaths()
    return result
  }

  private func check(_ code: Int32) throws {
    guard code == SQLITE_OK else { throw SubmissionError.storageFailure(code: code) }
  }

  private func openDirectory() throws {
    let path = directoryURL.path
    guard directoryURL.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0),
      Self.canonicalPath(directoryURL.deletingLastPathComponent().path)
        == directoryURL.deletingLastPathComponent().path
    else { throw SubmissionError.invalidStorage }
    if mkdir(path, 0o700) != 0 && errno != EEXIST { throw SubmissionError.invalidStorage }
    guard Self.canonicalPath(path) == path else { throw SubmissionError.invalidStorage }
    directoryDescriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryDescriptor >= 0 else { throw SubmissionError.invalidStorage }
    var information = stat()
    guard fstat(directoryDescriptor, &information) == 0,
      information.st_mode & S_IFMT == S_IFDIR, information.st_uid == geteuid(),
      information.st_mode & 0o777 == 0o700
    else { throw SubmissionError.invalidStorage }
  }

  private func openPrivateFile(_ name: String) throws -> Int32 {
    let descriptor = openat(
      directoryDescriptor, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw SubmissionError.invalidStorage }
    do {
      try validateRegularFile(descriptor)
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  private func validateRegularFile(_ descriptor: Int32) throws {
    var information = stat()
    guard fstat(descriptor, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG, information.st_nlink == 1,
      information.st_uid == geteuid(), information.st_mode & 0o777 == 0o600,
      information.st_size <= Self.maximumBytes
    else { throw SubmissionError.invalidStorage }
  }

  private func validatePaths() throws {
    var held = stat()
    var named = stat()
    guard Self.canonicalPath(directoryURL.path) == directoryURL.path,
      directoryDescriptor >= 0, fstat(directoryDescriptor, &held) == 0,
      lstat(directoryURL.path, &named) == 0, held.st_dev == named.st_dev,
      held.st_ino == named.st_ino,
      named.st_mode & S_IFMT == S_IFDIR, named.st_mode & 0o777 == 0o700,
      named.st_uid == geteuid()
    else { throw SubmissionError.invalidStorage }
    for (name, descriptor) in [
      (".owner", ownerDescriptor), ("submissions.sqlite3", databaseDescriptor),
    ] {
      try validateRegularFile(descriptor)
      guard fstat(descriptor, &held) == 0,
        fstatat(directoryDescriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
        held.st_dev == named.st_dev, held.st_ino == named.st_ino,
        named.st_mode & S_IFMT == S_IFREG
      else { throw SubmissionError.invalidStorage }
    }
    try validateSidecars()
  }

  private static func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private func validateSidecars() throws {
    for suffix in ["-journal", "-wal", "-shm"] {
      var information = stat()
      let status = fstatat(
        directoryDescriptor, "submissions.sqlite3" + suffix, &information, AT_SYMLINK_NOFOLLOW)
      if status != 0 {
        guard errno == ENOENT else { throw SubmissionError.invalidStorage }
        continue
      }
      guard suffix == "-journal", information.st_mode & S_IFMT == S_IFREG,
        information.st_nlink == 1, information.st_uid == geteuid(),
        information.st_mode & 0o777 == 0o600, information.st_size <= Self.maximumBytes
      else { throw SubmissionError.invalidStorage }
    }
  }

  private func closeResources() {
    if let database { sqlite3_close_v2(database) }
    database = nil
    if databaseDescriptor >= 0 { close(databaseDescriptor) }
    if ownsFileLock {
      // A duplicated descriptor can keep the flock alive after close, even with O_CLOEXEC.
      flock(ownerDescriptor, LOCK_UN)
      ownsFileLock = false
    }
    for descriptor in [ownerDescriptor, directoryDescriptor] where descriptor >= 0 {
      close(descriptor)
    }
    databaseDescriptor = -1
    ownerDescriptor = -1
    directoryDescriptor = -1
  }
}

enum SQLiteValue: Equatable {
  case text(String)
  case integer(Int64)
  case null
}
