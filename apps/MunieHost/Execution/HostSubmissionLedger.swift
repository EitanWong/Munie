import Darwin
import Foundation

/// Mac-only submission research boundary, consumed by the fault-injection executable.
/// Host administration and upstream observations below must never be exposed as mobile RPCs.
public actor HostSubmissionLedger {
  public static let maximumRequests = 10_000
  public let hostID: UUID
  private let storage: SQLiteStorage

  public init(directoryURL: URL, hostID: UUID) throws {
    let storage = try SQLiteStorage(directoryURL: directoryURL)
    try Self.initialize(storage, hostID: hostID)
    guard try storage.rows("PRAGMA quick_check(1)") == [[.text("ok")]] else {
      throw SubmissionError.corruptStore
    }
    // A process may die before or after sending bytes. Neither uncertain phase is replayable.
    try storage.transaction { database in
      try database.run(
        "UPDATE requests SET phase='reconciling' WHERE phase IN ('dispatching','running')")
    }
    self.hostID = hostID
    self.storage = storage
  }

  public var sqliteVersion: String { storage.sqliteVersion }

  /// Local owner action: pin an existing canonical directory, never a mobile-supplied cwd.
  public func registerProject(id: UUID, directoryURL: URL) throws {
    let project = try ProjectDirectory(directoryURL)
    try storage.transaction { database in
      let rows = try database.rows(
        "SELECT path,device,inode FROM projects WHERE id=?", [.text(id.uuidString)])
      if let existing = rows.first {
        guard existing == project.values else { throw SubmissionError.projectChanged }
        return
      }
      try database.run(
        "INSERT INTO projects(id,path,device,inode) VALUES(?,?,?,?)",
        [.text(id.uuidString)] + project.values)
    }
  }

  /// Local owner action. Revoked identities stay revoked; a future re-pair must use a new identity.
  public func authorizeDevice(id: UUID, projects: Set<UUID>) throws {
    guard !projects.isEmpty, projects.count <= 100 else { throw SubmissionError.invalidInput }
    try storage.transaction { database in
      let existing = try database.rows(
        "SELECT enabled FROM devices WHERE id=?", [.text(id.uuidString)])
      guard existing.isEmpty || existing == [[.integer(1)]] else {
        throw SubmissionError.unauthorized
      }
      for project in projects {
        guard
          try !database.rows("SELECT id FROM projects WHERE id=?", [.text(project.uuidString)])
            .isEmpty
        else { throw SubmissionError.unauthorized }
      }
      try database.run(
        "INSERT INTO devices(id,enabled) VALUES(?,1) ON CONFLICT(id) DO UPDATE SET enabled=1",
        [.text(id.uuidString)])
      try database.run("DELETE FROM grants WHERE device=?", [.text(id.uuidString)])
      for project in projects {
        try database.run(
          "INSERT INTO grants(device,project) VALUES(?,?)",
          [.text(id.uuidString), .text(project.uuidString)])
      }
    }
  }

  /// Denies future claim/read calls, including on already-established authenticated identities.
  /// Revocation does not assert that an already-dispatched upstream turn has stopped.
  public func revokeDevice(id: UUID) throws {
    try storage.run(
      "INSERT INTO devices(id,enabled) VALUES(?,0) ON CONFLICT(id) DO UPDATE SET enabled=0",
      [.text(id.uuidString)])
  }

  @discardableResult
  public func accept(_ request: TextSubmission, from device: AuthenticatedDevice) throws
    -> SubmissionSnapshot
  {
    try storage.transaction { database in
      _ = try authorizedProject(request, device: device, database: database)
      let identity = identity(request, device: device)
      if let previous = try record(request.requestID, database: database) {
        guard previous.identity.deviceID == device.id else { throw SubmissionError.unauthorized }
        guard previous.identity == identity else { throw SubmissionError.requestConflict }
        return previous.snapshot
      }
      let count = try database.rows("SELECT count(*) FROM requests")
      guard let row = count.first, case .integer(let total) = row.first,
        total < Self.maximumRequests
      else { throw SubmissionError.capacityExceeded }
      let encoded = try JSONEncoder().encode(identity)
      guard let json = String(data: encoded, encoding: .utf8) else {
        throw SubmissionError.invalidInput
      }
      try database.run(
        "INSERT INTO requests(id,identity,phase) VALUES(?,?,'accepted')",
        [.text(request.requestID.uuidString), .text(json)])
      return SubmissionSnapshot(requestID: request.requestID, phase: .accepted, upstream: nil)
    }
  }

  /// Commits dispatching BEFORE a caller can send to Codex. Duplicates never return another claim.
  public func claimForDispatch(_ request: TextSubmission, from device: AuthenticatedDevice) throws
    -> DispatchClaim
  {
    try storage.transaction { database in
      let directory = try authorizedProject(request, device: device, database: database)
      guard let previous = try record(request.requestID, database: database) else {
        throw SubmissionError.unknownRequest
      }
      guard previous.identity.deviceID == device.id else { throw SubmissionError.unauthorized }
      guard previous.identity == identity(request, device: device) else {
        throw SubmissionError.requestConflict
      }
      guard previous.snapshot.phase == .accepted else { return .existing(previous.snapshot) }
      try database.run(
        "UPDATE requests SET phase='dispatching' WHERE id=? AND phase='accepted'",
        [.text(request.requestID.uuidString)])
      guard database.changes == 1 else { throw SubmissionError.invalidTransition }
      return .send(AuthorizedSubmission(request: request, workingDirectory: directory))
    }
  }

  public func snapshot(requestID: UUID, from device: AuthenticatedDevice) throws
    -> SubmissionSnapshot
  {
    guard let previous = try record(requestID, database: storage) else {
      throw SubmissionError.unknownRequest
    }
    guard previous.identity.deviceID == device.id else { throw SubmissionError.unauthorized }
    _ = try authorizedProject(previous.identity, device: device, database: storage)
    return previous.snapshot
  }

  /// Trusted adapter observation, not an operation that a mobile client may assert.
  /// Reconciliation requires positive upstream evidence; no match means remain uncertain.
  public func observeStarted(requestID: UUID, upstream: UpstreamTurn) throws {
    try storage.transaction { database in
      guard let previous = try record(requestID, database: database) else {
        throw SubmissionError.unknownRequest
      }
      if previous.snapshot.phase == .running, previous.snapshot.upstream == upstream { return }
      guard [.dispatching, .reconciling].contains(previous.snapshot.phase),
        previous.snapshot.upstream == nil || previous.snapshot.upstream == upstream,
        previous.identity.threadID == nil || previous.identity.threadID == upstream.threadID
      else { throw SubmissionError.upstreamConflict }
      let project = previous.identity.projectID.uuidString
      let mapped = try database.rows(
        "SELECT project FROM threads WHERE id=?", [.text(upstream.threadID.uuidString)])
      if let row = mapped.first {
        guard row == [.text(project)] else { throw SubmissionError.upstreamConflict }
      } else {
        try database.run(
          "INSERT INTO threads(id,project) VALUES(?,?)",
          [.text(upstream.threadID.uuidString), .text(project)])
      }
      let collision = try database.rows(
        "SELECT id FROM requests WHERE thread=? AND turn=? AND id<>?",
        [
          .text(upstream.threadID.uuidString), .text(upstream.turnID.uuidString),
          .text(requestID.uuidString),
        ])
      guard collision.isEmpty else { throw SubmissionError.upstreamConflict }
      try database.run(
        "UPDATE requests SET phase='running',thread=?,turn=? WHERE id=?",
        [
          .text(upstream.threadID.uuidString), .text(upstream.turnID.uuidString),
          .text(requestID.uuidString),
        ])
    }
  }

  public func markUncertain(requestID: UUID) throws {
    guard let previous = try record(requestID, database: storage) else {
      throw SubmissionError.unknownRequest
    }
    guard [.dispatching, .running, .reconciling].contains(previous.snapshot.phase) else {
      throw SubmissionError.invalidTransition
    }
    try storage.run(
      "UPDATE requests SET phase='reconciling' WHERE id=?", [.text(requestID.uuidString)])
  }

  /// Trusted matching terminal notification. An interrupt RPC acknowledgment cannot call this.
  public func observeTerminal(requestID: UUID, upstream: UpstreamTurn, phase: SubmissionPhase)
    throws
  {
    guard [.completed, .failed, .cancelled].contains(phase) else {
      throw SubmissionError.invalidTransition
    }
    try storage.transaction { database in
      guard let previous = try record(requestID, database: database) else {
        throw SubmissionError.unknownRequest
      }
      guard previous.snapshot.upstream == upstream else { throw SubmissionError.upstreamConflict }
      if previous.snapshot.phase == phase { return }
      guard [.running, .reconciling].contains(previous.snapshot.phase) else {
        throw SubmissionError.invalidTransition
      }
      try database.run(
        "UPDATE requests SET phase=? WHERE id=?",
        [.text(phase.rawValue), .text(requestID.uuidString)])
    }
  }

  private static func initialize(_ database: SQLiteStorage, hostID: UUID) throws {
    let versions = try database.rows("PRAGMA user_version")
    guard versions == [[.integer(0)]] || versions == [[.integer(1)]] else {
      throw SubmissionError.unsupportedSchema
    }
    try database.transaction { database in
      if versions == [[.integer(0)]] {
        guard try database.rows("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else {
          throw SubmissionError.unsupportedSchema
        }
        let definitions = [
          "CREATE TABLE metadata(host TEXT PRIMARY KEY NOT NULL)",
          "CREATE TABLE projects(id TEXT PRIMARY KEY NOT NULL,path TEXT NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL)",
          "CREATE TABLE devices(id TEXT PRIMARY KEY NOT NULL,enabled INTEGER NOT NULL CHECK(enabled IN (0,1)))",
          "CREATE TABLE grants(device TEXT NOT NULL REFERENCES devices(id),project TEXT NOT NULL REFERENCES projects(id),PRIMARY KEY(device,project))",
          "CREATE TABLE threads(id TEXT PRIMARY KEY NOT NULL,project TEXT NOT NULL REFERENCES projects(id))",
          "CREATE TABLE requests(id TEXT PRIMARY KEY NOT NULL,identity TEXT NOT NULL,phase TEXT NOT NULL CHECK(phase IN ('accepted','dispatching','running','reconciling','completed','failed','cancelled')),thread TEXT,turn TEXT,CHECK((thread IS NULL)=(turn IS NULL)),UNIQUE(thread,turn))",
        ]
        for definition in definitions { try database.run(definition) }
        try database.run("INSERT INTO metadata(host) VALUES(?)", [.text(hostID.uuidString)])
        try database.run("PRAGMA user_version=1")
      }
      guard try database.rows("SELECT host FROM metadata") == [[.text(hostID.uuidString)]] else {
        throw SubmissionError.invalidStorage
      }
    }
  }

  private func identity(_ request: TextSubmission, device: AuthenticatedDevice)
    -> SubmissionIdentity
  {
    SubmissionIdentity(
      requestID: request.requestID, deviceID: device.id, hostID: request.hostID,
      projectID: request.projectID, threadID: request.threadID,
      payloadDigest: request.payloadDigest,
      harnessID: "codex", operation: "startTextTurn")
  }

  private func authorizedProject(
    _ request: TextSubmission, device: AuthenticatedDevice, database: SQLiteStorage
  ) throws -> URL {
    try authorizedProject(identity(request, device: device), device: device, database: database)
  }

  private func authorizedProject(
    _ identity: SubmissionIdentity, device: AuthenticatedDevice, database: SQLiteStorage
  ) throws -> URL {
    guard identity.hostID == hostID else { throw SubmissionError.unauthorized }
    let rows = try database.rows(
      "SELECT p.path,p.device,p.inode FROM projects p JOIN grants g ON g.project=p.id JOIN devices d ON d.id=g.device WHERE p.id=? AND d.id=? AND d.enabled=1",
      [.text(identity.projectID.uuidString), .text(device.id.uuidString)])
    guard let values = rows.first, values.count == 3, case .text(let path) = values[0] else {
      throw SubmissionError.unauthorized
    }
    let current: ProjectDirectory
    do { current = try ProjectDirectory(URL(fileURLWithPath: path, isDirectory: true)) } catch {
      throw SubmissionError.projectChanged
    }
    guard current.values == values else { throw SubmissionError.projectChanged }
    if let thread = identity.threadID {
      guard
        try database.rows("SELECT project FROM threads WHERE id=?", [.text(thread.uuidString)])
          == [[.text(identity.projectID.uuidString)]]
      else { throw SubmissionError.unauthorized }
    }
    return current.url
  }

  private func record(_ id: UUID, database: SQLiteStorage) throws -> Record? {
    let rows = try database.rows(
      "SELECT identity,phase,thread,turn FROM requests WHERE id=?", [.text(id.uuidString)])
    guard let row = rows.first else { return nil }
    guard row.count == 4, case .text(let json) = row[0], case .text(let rawPhase) = row[1],
      let phase = SubmissionPhase(rawValue: rawPhase), let data = json.data(using: .utf8),
      let identity = try? JSONDecoder().decode(SubmissionIdentity.self, from: data),
      identity.requestID == id, identity.hostID == hostID,
      identity.harnessID == "codex", identity.operation == "startTextTurn"
    else { throw SubmissionError.corruptStore }
    let upstream: UpstreamTurn?
    switch (row[2], row[3]) {
    case (.null, .null): upstream = nil
    case (.text(let thread), .text(let turn)):
      guard let threadID = UUID(uuidString: thread), let turnID = UUID(uuidString: turn) else {
        throw SubmissionError.corruptStore
      }
      upstream = UpstreamTurn(threadID: threadID, turnID: turnID)
    default: throw SubmissionError.corruptStore
    }
    guard ![.accepted, .dispatching].contains(phase) || upstream == nil,
      ![.running, .completed, .failed, .cancelled].contains(phase) || upstream != nil
    else { throw SubmissionError.corruptStore }
    return Record(
      identity: identity,
      snapshot: SubmissionSnapshot(requestID: id, phase: phase, upstream: upstream))
  }

  private struct Record {
    let identity: SubmissionIdentity
    let snapshot: SubmissionSnapshot
  }
}

private struct ProjectDirectory {
  let url: URL
  let values: [SQLiteValue]

  init(_ url: URL) throws {
    guard url.isFileURL, !url.path.utf8.contains(0), url.path.utf8.count <= 4096 else {
      throw SubmissionError.invalidInput
    }
    let normalized = url
    guard let resolved = realpath(normalized.path, nil) else {
      throw SubmissionError.projectChanged
    }
    defer { free(resolved) }
    guard normalized.path == String(cString: resolved) else {
      throw SubmissionError.projectChanged
    }
    var info = stat()
    guard lstat(normalized.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw SubmissionError.projectChanged
    }
    self.url = normalized
    self.values = [
      .text(normalized.path), .integer(Int64(info.st_dev)), .integer(Int64(info.st_ino)),
    ]
  }
}
