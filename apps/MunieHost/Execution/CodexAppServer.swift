import Darwin
import Foundation

/// Deliberately limited, pinned 0.162.1 client. Unsupported native capabilities fail closed.
public actor CodexAppServer: CodexExecutionAdapter {
  public static let supportedVersion = "0.162.1"
  private let transport: any CodexRPCTransport
  private let directory: String
  private let codexHome: String
  private let maximumBufferedEvents: Int
  private var initialized = false
  private var initializing = false
  private var starting = false
  private var closed = false
  private var failure: CodexClientError?
  private var reader: Task<Void, Never>?
  private var serial: Int64 = 0
  private var pending: [Int64: CheckedContinuation<CodexJSON, any Error>] = [:]
  private var timers: [Int64: Task<Void, Never>] = [:]
  private var senders: [Int64: Task<Void, Never>] = [:]
  private var frames: [(CodexJSON, Int)] = []
  private var frameBytes = 0
  private var eventWaiter: CheckedContinuation<CodexJSON, any Error>?
  private var consumingEvent = false
  private var knownThreads: Set<UUID> = []
  private var knownTurns: Set<UpstreamTurnKey> = []
  private var requests: [UpstreamTurnKey: UUID] = [:]
  private var active: UpstreamTurn?
  private var terminalTurns: Set<UpstreamTurnKey> = []
  private var receivedTerminals: Set<UpstreamTurnKey> = []
  private var receivedResolutions: Set<CodexRPCID> = []
  private var commandItems: [Data: (String, String)] = [:]
  private var serverRequestIDs: Set<CodexRPCID> = []
  private var approvals: [CodexRPCID: CodexCommandApproval] = [:]
  private var answeredApprovals: Set<CodexRPCID> = []

  private struct UpstreamTurnKey: Hashable {
    let thread: UUID
    let turn: UUID
    init(_ upstream: UpstreamTurn) {
      thread = upstream.threadID
      turn = upstream.turnID
    }
  }

  public init(
    transport: any CodexRPCTransport, workingDirectoryURL: URL, codexHomeURL: URL,
    maximumBufferedEvents: Int = 256
  ) throws {
    guard workingDirectoryURL.isFileURL, codexHomeURL.isFileURL,
      workingDirectoryURL.path.hasPrefix("/"), codexHomeURL.path.hasPrefix("/"),
      (1...1024).contains(maximumBufferedEvents)
    else { throw CodexClientError.invalidConfiguration }
    self.transport = transport
    self.directory = try Self.canonicalDirectory(workingDirectoryURL)
    self.codexHome = try Self.canonicalDirectory(codexHomeURL)
    self.maximumBufferedEvents = maximumBufferedEvents
  }

  public func initialize() async throws {
    guard !initialized, !initializing else { throw CodexClientError.alreadyInitialized }
    try checkOpen()
    initializing = true
    defer { initializing = false }
    reader = Task { [weak self] in await self?.receiveLoop() }
    do {
      let result = try await rpc(
        "initialize",
        [
          "clientInfo": .object([
            "name": .string("munie_host"), "title": .string("Munie Host"),
            "version": .string("0.1.0"),
          ]),
          "capabilities": .object(["experimentalApi": .bool(false)]),
        ])
      let value = try object(result)
      guard let userAgent = value["userAgent"]?.string,
        userAgent.contains("/\(Self.supportedVersion) "),
        value["platformFamily"]?.string == "unix", value["platformOs"]?.string == "macos",
        Self.sameBytes(value["codexHome"]?.string, codexHome)
      else { throw CodexClientError.unsupportedVersion }
      try await transport.send(.object(["method": .string("initialized"), "params": .object([:])]))
      initialized = true
    } catch {
      let safe = safeError(error)
      fail(safe)
      throw safe
    }
  }

  public func start(_ submission: AuthorizedSubmission) async throws -> UpstreamTurn {
    try checkInitialized()
    guard !starting, active == nil else { throw CodexClientError.busy }
    guard Self.sameBytes(try? Self.canonicalDirectory(submission.workingDirectory), directory)
    else { throw CodexClientError.permissionMismatch }
    guard knownTurns.count < 1024 else { throw CodexClientError.eventLimit }
    starting = true
    defer { starting = false }
    do {
      var params: [String: CodexJSON] = [
        "cwd": .string(directory), "approvalPolicy": .string("on-request"),
        "approvalsReviewer": .string("user"), "sandbox": .string("read-only"),
      ]
      let threadID: UUID
      if let existing = submission.request.threadID {
        params["threadId"] = .string(native(existing))
        params["excludeTurns"] = .bool(true)
        let result = try await rpc("thread/resume", params)
        threadID = try validateThread(result, expected: existing, verifyPermissions: true)
      } else {
        params["ephemeral"] = .bool(false)
        let result = try await rpc("thread/start", params)
        threadID = try validateThread(result, expected: nil, verifyPermissions: true)
      }
      knownThreads.insert(threadID)
      let result = try await rpc(
        "turn/start",
        [
          "threadId": .string(native(threadID)), "cwd": .string(directory),
          "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user"),
          "sandboxPolicy": .object(["type": .string("readOnly"), "networkAccess": .bool(false)]),
          "input": .array([
            .object(["type": .string("text"), "text": .string(submission.request.text)])
          ]),
        ])
      let turn = try object(try required(result, "turn"))
      let turnID = try uuid(turn["id"])
      guard turn["status"]?.string == "inProgress" else { throw CodexClientError.invalidTransition }
      let upstream = UpstreamTurn(threadID: threadID, turnID: turnID)
      let key = UpstreamTurnKey(upstream)
      guard !knownTurns.contains(key) else { throw CodexClientError.identityMismatch }
      knownTurns.insert(key)
      requests[key] = submission.request.requestID
      active = upstream
      return upstream
    } catch {
      let safe = safeError(error)
      fail(safe)
      throw safe
    }
  }

  public func nextEvent() async throws -> CodexNativeEvent {
    try checkInitialized()
    guard !consumingEvent, !starting else { throw CodexClientError.busy }
    consumingEvent = true
    defer { consumingEvent = false }
    do {
      let frame: CodexJSON
      if !frames.isEmpty {
        let first = frames.removeFirst()
        frameBytes -= first.1
        frame = first.0
      } else {
        frame = try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            eventWaiter = continuation
          }
        } onCancel: {
          Task { await self.cancelEventWaiter() }
        }
      }
      return try parseEvent(frame)
    } catch {
      let safe = safeError(error)
      fail(safe)
      throw safe
    }
  }

  public func interrupt(_ upstream: UpstreamTurn) async throws {
    try checkInitialized()
    guard active == upstream, !terminalTurns.contains(UpstreamTurnKey(upstream)) else {
      throw CodexClientError.invalidTransition
    }
    let result = try await rpc(
      "turn/interrupt",
      [
        "threadId": .string(native(upstream.threadID)), "turnId": .string(native(upstream.turnID)),
      ])
    guard try object(result).isEmpty else { throw CodexClientError.malformedFrame }
    // Acknowledgement only: active remains until a matching turn/completed notification.
  }

  public func read(_ upstream: UpstreamTurn) async throws -> CodexTurnSnapshot? {
    try checkInitialized()
    let result = try await rpc(
      "thread/read",
      [
        "threadId": .string(native(upstream.threadID)), "includeTurns": .bool(false),
      ])
    _ = try validateThread(result, expected: upstream.threadID, verifyPermissions: false)
    knownThreads.insert(upstream.threadID)
    var cursor: String?
    var cursors: Set<Data> = []
    for _ in 0..<32 {
      var params: [String: CodexJSON] = [
        "threadId": .string(native(upstream.threadID)), "limit": .integer(100),
        "sortDirection": .string("desc"), "itemsView": .string("full"),
      ]
      if let cursor { params["cursor"] = .string(cursor) }
      let page = try object(try await rpc("thread/turns/list", params))
      guard let turns = page["data"]?.array, turns.count <= 100 else {
        throw CodexClientError.malformedFrame
      }
      var found: CodexTurnSnapshot?
      var pageIDs: Set<UUID> = []
      for value in turns {
        let turn = try object(value)
        let id = try uuid(turn["id"])
        guard pageIDs.insert(id).inserted,
          let statusString = turn["status"]?.string,
          let status = CodexTurnStatus(rawValue: statusString)
        else { throw CodexClientError.malformedFrame }
        if id == upstream.turnID { found = CodexTurnSnapshot(upstream: upstream, status: status) }
      }
      if let found {
        knownTurns.insert(UpstreamTurnKey(upstream))
        return found
      }
      guard let next = page["nextCursor"], next != .null else { return nil }
      guard let value = next.string, !value.isEmpty, value.utf8.count <= 4096,
        cursors.insert(Data(value.utf8)).inserted
      else { throw CodexClientError.paginationLimit }
      cursor = value
    }
    throw CodexClientError.paginationLimit
  }

  public func respondApproval(_ approval: CodexCommandApproval, decision: CodexApprovalDecision)
    async throws
  {
    try checkInitialized()
    guard approvals[approval.rpcID] == approval,
      !answeredApprovals.contains(approval.rpcID), active == approval.upstream,
      !receivedResolutions.contains(approval.rpcID),
      !receivedTerminals.contains(UpstreamTurnKey(approval.upstream))
    else { throw CodexClientError.staleApproval }
    guard approval.availableDecisions.contains(.string(decision.rawValue)) else {
      throw CodexClientError.unavailableDecision
    }
    // Mark before suspension: two concurrent callers can never reply to one native request.
    answeredApprovals.insert(approval.rpcID)
    do {
      try await transport.send(
        .object([
          "id": jsonID(approval.rpcID),
          "result": .object(["decision": .string(decision.rawValue)]),
        ]))
    } catch {
      let safe = safeError(error)
      fail(safe)
      throw safe
    }
  }

  public func close() async throws -> CodexTransportCleanup {
    closed = true
    fail(.closed)
    defer { reader?.cancel() }
    return try await transport.shutdown()
  }

  private func rpc(_ method: String, _ params: [String: CodexJSON]) async throws -> CodexJSON {
    try checkOpen()
    guard pending.count < 4, serial < Int64.max else { throw CodexClientError.busy }
    serial += 1
    let id = serial
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        timers[id] = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(10)) } catch { return }
          await self?.rpcTimedOut(id)
        }
        senders[id] = Task { [weak self, transport] in
          do {
            try await transport.send(
              .object([
                "id": .integer(id), "method": .string(method), "params": .object(params),
              ]))
            await self?.senderFinished(id)
          } catch { await self?.sendFailed(error, id: id) }
        }
      }
    } onCancel: {
      Task { await self.fail(.transport) }
    }
  }

  private func receiveLoop() async {
    do {
      while !Task.isCancelled {
        let frame = try await transport.receive()
        try consumeFrame(frame)
      }
    } catch { fail(safeError(error)) }
  }

  private func consumeFrame(_ frame: CodexJSON) throws {
    let value = try object(frame)
    if let version = value["jsonrpc"], version != .string("2.0") {
      throw CodexClientError.malformedFrame
    }
    if let methodValue = value["method"] {
      guard Set(value.keys).isSubset(of: ["jsonrpc", "method", "id", "params", "emittedAtMs"]),
        value["emittedAtMs"] == nil || value["emittedAtMs"]?.integer != nil,
        let method = methodValue.string, value["params"]?.object != nil
      else { throw CodexClientError.malformedFrame }
      if let id = value["id"] {
        guard method == "item/commandExecution/requestApproval" else {
          throw CodexClientError.unsupportedMethod
        }
        let nativeID = try rpcID(id)
        guard serverRequestIDs.count < 1024, serverRequestIDs.insert(nativeID).inserted else {
          throw CodexClientError.responseMismatch
        }
      } else if !Self.notifications.contains(method) {
        throw CodexClientError.unsupportedMethod
      }
      let params = try object(value["params"]!)
      if method == "turn/completed" {
        let turn = try object(try required(value["params"]!, "turn"))
        let upstream = UpstreamTurn(
          threadID: try uuid(params["threadId"]), turnID: try uuid(turn["id"]))
        guard receivedTerminals.count < 1024 else { throw CodexClientError.eventLimit }
        receivedTerminals.insert(UpstreamTurnKey(upstream))
      } else if method == "serverRequest/resolved" {
        guard receivedResolutions.count < 1024 else { throw CodexClientError.eventLimit }
        receivedResolutions.insert(try rpcID(params["requestId"]))
      }
      let size = try frame.encoded().count
      guard frames.count < maximumBufferedEvents, frameBytes + size <= 4 * 1024 * 1024 else {
        throw CodexClientError.eventLimit
      }
      if let waiter = eventWaiter {
        eventWaiter = nil
        waiter.resume(returning: frame)
      } else {
        frames.append((frame, size))
        frameBytes += size
      }
      return
    }
    guard Set(value.keys).isSubset(of: ["jsonrpc", "id", "result", "error"]),
      let id = value["id"]?.integer, let continuation = pending[id],
      (value["result"] != nil) != (value["error"] != nil)
    else { throw CodexClientError.responseMismatch }
    pending.removeValue(forKey: id)
    timers.removeValue(forKey: id)?.cancel()
    if let error = value["error"] {
      guard let details = error.object, let code = details["code"]?.integer,
        details["message"]?.string != nil
      else {
        continuation.resume(throwing: CodexClientError.malformedFrame)
        throw CodexClientError.malformedFrame
      }
      continuation.resume(throwing: CodexClientError.rpc(code: code))
    } else if let result = value["result"], result.object != nil {
      continuation.resume(returning: result)
    } else {
      continuation.resume(throwing: CodexClientError.malformedFrame)
      throw CodexClientError.malformedFrame
    }
  }

  private func parseEvent(_ frame: CodexJSON) throws -> CodexNativeEvent {
    let value = try object(frame)
    guard let method = value["method"]?.string, let payload = value["params"] else {
      throw CodexClientError.malformedFrame
    }
    let params = try object(payload)
    var threadID: UUID?
    var turnID: UUID?
    var itemID = params["itemId"]?.string
    var kind = CodexNativeEvent.Kind.progress
    if method == "remoteControl/status/changed" {
      guard params["status"]?.string == "disabled" else {
        throw CodexClientError.permissionMismatch
      }
      // Host identity fields remain host-only payload and must not reach diagnostics.
    } else if method != "account/rateLimits/updated" {
      if method == "thread/started" {
        let thread = try object(try required(payload, "thread"))
        threadID = try uuid(thread["id"])
        guard Self.sameBytes(thread["cwd"]?.string, directory) else {
          throw CodexClientError.permissionMismatch
        }
      } else {
        threadID = try uuid(params["threadId"])
      }
      guard let threadID, knownThreads.contains(threadID) else {
        throw CodexClientError.identityMismatch
      }
      if method == "turn/started" || method == "turn/completed" {
        let turn = try object(try required(payload, "turn"))
        turnID = try uuid(turn["id"])
        let upstream = UpstreamTurn(threadID: threadID, turnID: turnID!)
        let key = UpstreamTurnKey(upstream)
        guard knownTurns.contains(key), let statusText = turn["status"]?.string,
          let status = CodexTurnStatus(rawValue: statusText)
        else { throw CodexClientError.identityMismatch }
        if method == "turn/completed" {
          guard status.isTerminal, terminalTurns.insert(key).inserted else {
            throw CodexClientError.invalidTransition
          }
          if active == upstream { active = nil }
          kind = .terminal(CodexTurnSnapshot(upstream: upstream, status: status))
        } else if status != .inProgress || terminalTurns.contains(key) {
          throw CodexClientError.invalidTransition
        }
      } else if method.hasPrefix("item/") || params["turnId"] != nil {
        turnID = try uuid(params["turnId"])
        let upstream = UpstreamTurn(threadID: threadID, turnID: turnID!)
        guard knownTurns.contains(UpstreamTurnKey(upstream)),
          !terminalTurns.contains(UpstreamTurnKey(upstream))
        else { throw CodexClientError.identityMismatch }
        if let item = params["item"]?.object { itemID = item["id"]?.string }
        if method.hasPrefix("item/"), itemID?.isEmpty != false {
          throw CodexClientError.malformedFrame
        }
        let itemKey = Data("\(native(threadID))/\(native(upstream.turnID))/\(itemID ?? "")".utf8)
        if method == "item/started", let item = params["item"]?.object,
          item["type"]?.string == "commandExecution"
        {
          guard let command = item["command"]?.string, let cwd = item["cwd"]?.string,
            commandItems.count < 1024
          else { throw CodexClientError.malformedFrame }
          commandItems[itemKey] = (command, cwd)
        }
        if method == "item/commandExecution/requestApproval" {
          let id = try rpcID(value["id"])
          guard params["kind"]?.string == "command", let command = params["command"]?.string,
            !command.isEmpty, Self.sameBytes(params["cwd"]?.string, directory),
            params["networkApprovalContext"] == nil || params["networkApprovalContext"] == .null,
            let decisions = params["availableDecisions"]?.array, !decisions.isEmpty,
            decisions.count <= 16, params["startedAtMs"]?.integer != nil,
            let action = commandItems[itemKey], Self.sameBytes(action.0, command),
            Self.sameBytes(action.1, directory),
            params["reason"] == nil || params["reason"] == .null || params["reason"]?.string != nil
          else { throw CodexClientError.unsupportedMethod }
          let approval = CodexCommandApproval(
            rpcID: id, upstream: upstream, itemID: itemID!, command: command,
            workingDirectory: directory, reason: params["reason"]?.string,
            availableDecisions: decisions, payload: payload)
          guard approvals[id] == nil else { throw CodexClientError.responseMismatch }
          approvals[id] = approval
          kind = .approval(approval)
        }
      } else if method == "serverRequest/resolved" {
        let id = try rpcID(params["requestId"])
        guard let approval = approvals.removeValue(forKey: id),
          approval.upstream.threadID == threadID
        else { throw CodexClientError.staleApproval }
        turnID = approval.upstream.turnID
        itemID = approval.itemID
        kind = .approvalResolved(id)
      }
    }
    let requestID: UUID?
    if let threadID, let turnID {
      requestID = requests[UpstreamTurnKey(UpstreamTurn(threadID: threadID, turnID: turnID))]
    } else {
      requestID = nil
    }
    return CodexNativeEvent(
      method: method, requestID: requestID, threadID: threadID, turnID: turnID, itemID: itemID,
      kind: kind, payload: payload)
  }

  private func validateThread(_ result: CodexJSON, expected: UUID?, verifyPermissions: Bool) throws
    -> UUID
  {
    let value = try object(result)
    let thread = try object(try required(result, "thread"))
    let id = try uuid(thread["id"])
    guard expected == nil || expected == id, Self.sameBytes(thread["cwd"]?.string, directory) else {
      throw CodexClientError.identityMismatch
    }
    if verifyPermissions {
      guard Self.sameBytes(value["cwd"]?.string, directory),
        value["approvalPolicy"]?.string == "on-request",
        value["approvalsReviewer"]?.string == "user", let sandbox = value["sandbox"]?.object,
        sandbox["type"]?.string == "readOnly",
        sandbox["networkAccess"] == nil || sandbox["networkAccess"] == .bool(false)
      else { throw CodexClientError.permissionMismatch }
    }
    return id
  }

  private static let notifications: Set<String> = [
    "remoteControl/status/changed", "thread/started", "thread/status/changed", "warning",
    "turn/started", "turn/completed", "item/started", "item/completed",
    "thread/tokenUsage/updated", "account/rateLimits/updated", "item/commandExecution/outputDelta",
    "item/agentMessage/delta", "serverRequest/resolved", "thread/goal/cleared",
  ]

  private func checkOpen() throws {
    if let failure { throw failure }
    guard !closed else { throw CodexClientError.closed }
  }

  private func checkInitialized() throws {
    try checkOpen()
    guard initialized else { throw CodexClientError.notInitialized }
  }

  private func fail(_ error: CodexClientError) {
    if failure == nil { failure = error }
    for timer in timers.values { timer.cancel() }
    timers.removeAll()
    for sender in senders.values { sender.cancel() }
    senders.removeAll()
    let waiters = pending.values
    pending.removeAll()
    for continuation in waiters { continuation.resume(throwing: error) }
    eventWaiter?.resume(throwing: error)
    eventWaiter = nil
  }

  private func rpcTimedOut(_ id: Int64) { if pending[id] != nil { fail(.transport) } }
  private func cancelEventWaiter() { fail(.transport) }
  private func senderFinished(_ id: Int64) { senders.removeValue(forKey: id) }
  private func sendFailed(_ error: any Error, id: Int64) {
    senders.removeValue(forKey: id)
    fail(safeError(error))
  }
  private func safeError(_ error: any Error) -> CodexClientError {
    if let error = error as? CodexClientError { return error }
    if let error = error as? CodexTransportError { return .transportFailure(error) }
    return .transport
  }

  private func object(_ value: CodexJSON) throws -> [String: CodexJSON] {
    guard let object = value.object else { throw CodexClientError.malformedFrame }
    return object
  }

  private func required(_ value: CodexJSON, _ key: String) throws -> CodexJSON {
    guard let result = value.object?[key] else { throw CodexClientError.malformedFrame }
    return result
  }

  private func uuid(_ value: CodexJSON?) throws -> UUID {
    guard let text = value?.string, let id = UUID(uuidString: text), native(id) == text else {
      throw CodexClientError.identityMismatch
    }
    return id
  }

  private func native(_ id: UUID) -> String { id.uuidString.lowercased() }
  private static func sameBytes(_ left: String?, _ right: String) -> Bool {
    left?.utf8.elementsEqual(right.utf8) == true
  }
  private static func canonicalDirectory(_ url: URL) throws -> String {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
      url.path.utf8.count <= 4096, let resolved = realpath(url.path, nil)
    else { throw CodexClientError.invalidConfiguration }
    defer { free(resolved) }
    var info = stat()
    guard Self.sameBytes(url.path, String(cString: resolved)), lstat(url.path, &info) == 0,
      info.st_mode & S_IFMT == S_IFDIR
    else { throw CodexClientError.invalidConfiguration }
    return url.path
  }
  private func rpcID(_ value: CodexJSON?) throws -> CodexRPCID {
    if let integer = value?.integer { return .integer(integer) }
    if let string = value?.string, !string.isEmpty, string.utf8.count <= 256 {
      return .string(string)
    }
    throw CodexClientError.malformedFrame
  }

  private func jsonID(_ id: CodexRPCID) -> CodexJSON {
    switch id {
    case .integer(let value): .integer(value)
    case .string(let value): .string(value)
    }
  }
}
