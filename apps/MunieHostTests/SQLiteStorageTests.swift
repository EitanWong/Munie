import Darwin
import Foundation
import SQLite3
import Testing

@testable import MunieExecutionHost

struct SQLiteStorageTests {
  @Test func bindsUnicodeEmbeddedNULAndSQLAsDataWithoutTruncation() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try SQLiteStorage(directoryURL: fixture.directory)
    try store.run("CREATE TABLE values_table (value TEXT, number INTEGER, optional TEXT)")
    let text = "你好 👩🏽‍💻\0后半段'); DROP TABLE values_table; --"
    try store.run(
      "INSERT INTO values_table VALUES (?, ?, ?)", [.text(text), .integer(Int64.max), .null])
    #expect(store.changes == 1)
    #expect(
      try store.rows("SELECT value, number, optional FROM values_table") == [
        [.text(text), .integer(Int64.max), .null]
      ])
    #expect(!store.sqliteVersion.isEmpty)
  }

  @Test func transactionRollsBackAndPreservesOriginalBodyError() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try SQLiteStorage(directoryURL: fixture.directory)
    try store.run("CREATE TABLE records (value TEXT UNIQUE)")
    try store.run("INSERT INTO records VALUES (?)", [.text("pristine")])
    #expect(throws: MarkerError.syntheticFailure) {
      try store.transaction { database in
        try database.run("INSERT INTO records VALUES (?)", [.text("discard")])
        throw MarkerError.syntheticFailure
      }
    }
    #expect(try store.rows("SELECT value FROM records") == [[.text("pristine")]])
    let value = try store.transaction { database in
      try database.run("INSERT INTO records VALUES (?)", [.text("committed")])
      return 42
    }
    #expect(value == 42)
    #expect(try store.rows("SELECT COUNT(*) FROM records") == [[.integer(2)]])
  }

  @Test func sqliteFailureRollsBackPriorStatementsAndExposesOnlyCode() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try SQLiteStorage(directoryURL: fixture.directory)
    try store.run("CREATE TABLE records (value TEXT UNIQUE)")
    try store.run("INSERT INTO records VALUES ('pristine')")
    #expect(throws: SubmissionError.storageFailure(code: SQLITE_CONSTRAINT)) {
      try store.transaction { database in
        try database.run("INSERT INTO records VALUES ('discard')")
        try database.run("INSERT INTO records VALUES ('pristine')")
      }
    }
    #expect(try store.rows("SELECT value FROM records") == [[.text("pristine")]])
    do {
      try store.run("SELECT private_token_synthetic FROM missing_private_table")
      Issue.record("Invalid SQL unexpectedly succeeded")
    } catch let error as SubmissionError {
      #expect(error == .storageFailure(code: SQLITE_ERROR))
      #expect(!String(describing: error).contains("private_token"))
      #expect(!String(describing: error).contains(fixture.directory.path))
    }
  }

  @Test func nestedTransactionIsRejectedWithoutCommittingOuterChanges() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try SQLiteStorage(directoryURL: fixture.directory)
    try store.run("CREATE TABLE records (value TEXT)")
    try store.run("INSERT INTO records VALUES ('pristine')")
    #expect(throws: SubmissionError.storageFailure(code: SQLITE_MISUSE)) {
      try store.transaction { database in
        try database.run("INSERT INTO records VALUES ('discard')")
        try database.transaction { _ in }
      }
    }
    #expect(try store.rows("SELECT value FROM records") == [[.text("pristine")]])
    try store.transaction { database in
      try database.run("INSERT INTO records VALUES ('committed')")
    }
    #expect(try store.rows("SELECT COUNT(*) FROM records") == [[.integer(2)]])
  }

  @Test func rollbackValidationFailureClosesConnectionAndPreservesBodyError() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try SQLiteStorage(directoryURL: fixture.directory)
    try store.run("CREATE TABLE records (value TEXT)")
    try store.run("INSERT INTO records VALUES ('pristine')")
    #expect(throws: MarkerError.syntheticFailure) {
      try store.transaction { database in
        try database.run("INSERT INTO records VALUES ('discard')")
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o644], ofItemAtPath: fixture.file().path)
        throw MarkerError.syntheticFailure
      }
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fixture.file().path)
    #expect(throws: SubmissionError.storageFailure(code: SQLITE_MISUSE)) {
      try store.rows("SELECT 1")
    }
    #expect(throws: SubmissionError.storageFailure(code: SQLITE_MISUSE)) {
      try store.transaction { _ in }
    }
    #expect(store.changes == 0)
    let reopened = try SQLiteStorage(directoryURL: fixture.directory)
    #expect(try reopened.rows("SELECT value FROM records") == [[.text("pristine")]])
  }

  @Test func fullPageBudgetPreservesPristineDataAndAllowsRecovery() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try SQLiteStorage(directoryURL: fixture.directory)
    try store.run("CREATE TABLE records (value TEXT)")
    try store.run("INSERT INTO records VALUES ('pristine')")
    let pageCount = try store.rows("PRAGMA page_count")
    guard case .integer(let pages) = pageCount.first?.first else {
      Issue.record("Missing page count")
      return
    }
    try store.run("PRAGMA max_page_count = \(pages)")
    #expect(throws: SubmissionError.storageFailure(code: SQLITE_FULL)) {
      try store.transaction { database in
        try database.run("UPDATE records SET value = 'discard'")
        try database.run(
          "INSERT INTO records VALUES (?)", [.text(String(repeating: "x", count: 100_000))])
      }
    }
    #expect(try store.rows("SELECT value FROM records") == [[.text("pristine")]])
    try store.run("PRAGMA max_page_count = 16384")
    try store.run("INSERT INTO records VALUES ('recovered')")
    #expect(try store.rows("SELECT COUNT(*) FROM records") == [[.integer(2)]])
  }

  @Test func configurationIsDurableAndSchemaVersionIsNotOverwritten() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    do {
      let store = try SQLiteStorage(directoryURL: fixture.directory)
      #expect(try store.rows("PRAGMA journal_mode") == [[.text("delete")]])
      #expect(try store.rows("PRAGMA synchronous") == [[.integer(3)]])
      #expect(try store.rows("PRAGMA fullfsync") == [[.integer(1)]])
      #expect(try store.rows("PRAGMA foreign_keys") == [[.integer(1)]])
      #expect(try store.rows("PRAGMA trusted_schema") == [[.integer(0)]])
      #expect(try store.rows("PRAGMA busy_timeout") == [[.integer(250)]])
      #expect(try store.rows("PRAGMA max_page_count") == [[.integer(16384)]])
      try store.run("PRAGMA user_version = 47")
      try store.run("CREATE TABLE retained (value TEXT)")
      try store.run("INSERT INTO retained VALUES ('survives-reopen')")
    }
    let reopened = try SQLiteStorage(directoryURL: fixture.directory)
    #expect(try reopened.rows("PRAGMA user_version") == [[.integer(47)]])
    #expect(try reopened.rows("SELECT value FROM retained") == [[.text("survives-reopen")]])
    #expect(!FileManager.default.fileExists(atPath: fixture.file("-wal").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.file("-shm").path))
  }

  @Test func privateModesAndOneLifetimeOwnerAreEnforced() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var store: SQLiteStorage? = try SQLiteStorage(directoryURL: fixture.directory)
    #expect(try mode(fixture.directory) == 0o700)
    #expect(try mode(fixture.directory.appendingPathComponent(".owner")) == 0o600)
    #expect(try mode(fixture.file()) == 0o600)
    #expect(throws: SubmissionError.storeBusy) {
      try SQLiteStorage(directoryURL: fixture.directory)
    }
    #expect(store?.sqliteVersion.isEmpty == false)
    store = nil
    let reopened = try SQLiteStorage(directoryURL: fixture.directory)
    #expect(try reopened.rows("SELECT 1") == [[.integer(1)]])
  }

  @Test func separateProcessCannotAcquireOwnedFileLockAndReleaseRestoresIt() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let lock = fixture.directory.appendingPathComponent(".owner")
    var store: SQLiteStorage? = try SQLiteStorage(directoryURL: fixture.directory)
    let code = """
      import fcntl, os, sys
      fd = os.open(sys.argv[1], os.O_RDWR)
      try:
          fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      except BlockingIOError:
          sys.exit(75)
      finally:
          os.close(fd)
      """
    #expect(try python(code, arguments: [lock.path]) == 75)
    #expect(store != nil)
    store = nil
    #expect(try python(code, arguments: [lock.path]) == 0)
  }

  @Test func closingStoreReleasesLockEvenWhileADuplicateDescriptorIsOpen() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var store: SQLiteStorage? = try SQLiteStorage(directoryURL: fixture.directory)
    let lock = fixture.directory.appendingPathComponent(".owner")
    var owner = stat()
    try #require(stat(lock.path, &owner) == 0)
    // Model the short-lived reference inherited by a process between fork and exec.
    let descriptor = try withExtendedLifetime(store) {
      let candidates = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
      return try #require(
        candidates.compactMap { name -> Int32? in
          guard let descriptor = Int32(name) else { return nil }
          var information = stat()
          guard fstat(descriptor, &information) == 0,
            information.st_dev == owner.st_dev, information.st_ino == owner.st_ino
          else { return nil }
          return descriptor
        }.first)
    }
    let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
    try #require(duplicate >= 0)
    defer { close(duplicate) }
    #expect(throws: SubmissionError.storeBusy) {
      try SQLiteStorage(directoryURL: fixture.directory)
    }
    store = nil
    let reopened = try SQLiteStorage(directoryURL: fixture.directory)
    #expect(try reopened.rows("SELECT 1") == [[.integer(1)]])
  }

  @Test func separatelyOwnedLockReturnsBusyAndReleasesAfterProcessExit() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    do { _ = try SQLiteStorage(directoryURL: fixture.directory) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-I", "-c",
      """
      import fcntl, os, sys
      fd = os.open(sys.argv[1], os.O_RDWR)
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      sys.stdout.write("R")
      sys.stdout.flush()
      sys.stdin.read(1)
      os.close(fd)
      """,
      fixture.directory.appendingPathComponent(".owner").path,
    ]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      try? input.fileHandleForWriting.close()
      process.waitUntilExit()
    }
    #expect(try output.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
    #expect(throws: SubmissionError.storeBusy) {
      try SQLiteStorage(directoryURL: fixture.directory)
    }
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let reopened = try SQLiteStorage(directoryURL: fixture.directory)
    #expect(try reopened.rows("SELECT 1") == [[.integer(1)]])
  }

  @Test func directorySymlinkAndUnsafePermissionsAreRejectedWithoutMutation() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
    #expect(throws: SubmissionError.invalidStorage) {
      try SQLiteStorage(directoryURL: fixture.directory)
    }
    #expect(try mode(fixture.directory) == 0o755)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
    let link = fixture.parent.appendingPathComponent("directory-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
    #expect(throws: SubmissionError.invalidStorage) { try SQLiteStorage(directoryURL: link) }
  }

  @Test func symlinkedAncestorAndNonFileURLAreRejected() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let real = fixture.parent.appendingPathComponent("real-parent", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    let link = fixture.parent.appendingPathComponent("linked-parent", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(throws: SubmissionError.invalidStorage) {
      try SQLiteStorage(directoryURL: link.appendingPathComponent("child", isDirectory: true))
    }
    let remote = try #require(URL(string: "https://synthetic.invalid/storage"))
    #expect(throws: SubmissionError.invalidStorage) { try SQLiteStorage(directoryURL: remote) }
  }

  @Test func symlinkAndHardlinkDatabaseOrLockCannotAlterTargetBytes() throws {
    for name in ["submissions.sqlite3", ".owner"] {
      for hardlink in [false, true] {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
          at: fixture.directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        let target = fixture.parent.appendingPathComponent("pristine-target")
        let original = Data("synthetic-private-pristine".utf8)
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let named = fixture.directory.appendingPathComponent(name)
        if hardlink {
          try FileManager.default.linkItem(at: target, to: named)
        } else {
          try FileManager.default.createSymbolicLink(at: named, withDestinationURL: target)
        }
        #expect(throws: SubmissionError.invalidStorage) {
          try SQLiteStorage(directoryURL: fixture.directory)
        }
        #expect(try Data(contentsOf: target) == original)
      }
    }
  }

  @Test func nonRegularDatabaseAndOwnerFilesAreRejectedWithoutBlocking() throws {
    for name in ["submissions.sqlite3", ".owner"] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      try FileManager.default.createDirectory(
        at: fixture.directory, withIntermediateDirectories: false)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
      let named = fixture.directory.appendingPathComponent(name)
      #expect(mkfifo(named.path, 0o600) == 0)
      #expect(throws: SubmissionError.invalidStorage) {
        try SQLiteStorage(directoryURL: fixture.directory)
      }
      var information = stat()
      #expect(lstat(named.path, &information) == 0)
      #expect(information.st_mode & S_IFMT == S_IFIFO)
    }
  }

  @Test func unsafeJournalAndWALSidecarsAreRejectedBeforeSQLiteOpens() throws {
    for suffix in ["-journal", "-wal", "-shm"] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      do { _ = try SQLiteStorage(directoryURL: fixture.directory) }
      let original = try Data(contentsOf: fixture.file())
      let target = fixture.parent.appendingPathComponent("outside-target")
      try Data("unchanged".utf8).write(to: target)
      try FileManager.default.createSymbolicLink(
        at: fixture.file(suffix), withDestinationURL: target)
      #expect(throws: SubmissionError.invalidStorage) {
        try SQLiteStorage(directoryURL: fixture.directory)
      }
      #expect(try Data(contentsOf: fixture.file()) == original)
      #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
    }
  }

  @Test func failedInitializationReleasesExclusiveOwner() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
      at: fixture.directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
    try Data("not a sqlite database".utf8).write(to: fixture.file())
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fixture.file().path)
    #expect(throws: SubmissionError.self) { try SQLiteStorage(directoryURL: fixture.directory) }
    try FileManager.default.removeItem(at: fixture.file())
    let store = try SQLiteStorage(directoryURL: fixture.directory)
    #expect(try store.rows("SELECT 1") == [[.integer(1)]])
  }

  @Test func replacedDatabasePathOrPermissionsAreRejectedDuringLifetime() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try SQLiteStorage(directoryURL: fixture.directory)
    try store.run("CREATE TABLE retained (value TEXT)")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.file().path)
    #expect(throws: SubmissionError.invalidStorage) { try store.rows("SELECT 1") }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fixture.file().path)
    let moved = fixture.parent.appendingPathComponent("original.sqlite3")
    try FileManager.default.moveItem(at: fixture.file(), to: moved)
    try Data("replacement".utf8).write(to: fixture.file())
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fixture.file().path)
    #expect(throws: SubmissionError.invalidStorage) { try store.rows("SELECT 1") }
    #expect(try Data(contentsOf: fixture.file()) == Data("replacement".utf8))
  }

  @Test func rowsAreBoundedAndBindingsAreExact() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try SQLiteStorage(directoryURL: fixture.directory)
    #expect(throws: SubmissionError.storageFailure(code: SQLITE_TOOBIG)) {
      try store.rows(
        "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10001) SELECT x FROM n"
      )
    }
    #expect(throws: SubmissionError.storageFailure(code: SQLITE_RANGE)) {
      try store.rows("SELECT ?")
    }
    #expect(throws: SubmissionError.storageFailure(code: SQLITE_RANGE)) {
      try store.rows("SELECT 1", [.text("extra")])
    }
    #expect(throws: SubmissionError.storageFailure(code: SQLITE_MISUSE)) {
      try store.run("SELECT 1; SELECT 2")
    }
    #expect(try store.rows("SELECT 1") == [[.integer(1)]])
  }

  private enum MarkerError: Error, Equatable { case syntheticFailure }

  private struct Fixture {
    let parent: URL
    let directory: URL

    init() throws {
      let temporary = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
      defer { free(temporary) }
      parent = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
        .appendingPathComponent("MunieSQLiteTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
      directory = parent.appendingPathComponent("private-store", isDirectory: true)
    }

    func file(_ suffix: String = "") -> URL {
      directory.appendingPathComponent("submissions.sqlite3" + suffix)
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }
  }

  private func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue
  }

  private func python(_ code: String, arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-I", "-c", code] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
}
