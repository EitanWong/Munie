import UIKit
import UserNotifications
import XCTest

@testable import MunieRemodex

@MainActor
final class MunieApprovalNotificationTests: XCTestCase {
  private var services: [CodexService] = []

  override func tearDown() async throws {
    await MunieTestServiceLifecycle.finish(services)
    services.removeAll()
    try await super.tearDown()
  }

  func testCompletionAndFailureNotificationsDoNotExposePrivateThreadTitle() async {
    let center = ApprovalNotificationCenter()
    let service = makeService(center)
    service.threads = [CodexThread(id: "thread", title: "PRIVATE_CUSTOMER_INCIDENT")]
    let delivered = expectation(description: "generic completion alerts")
    delivered.expectedFulfillmentCount = 2
    center.onAdd = { delivered.fulfill() }
    for result in [CodexRunCompletionResult.completed, .failed] {
      service.notifyRunCompletionIfNeeded(
        threadId: "thread", turnId: result.rawValue, result: result)
    }
    await fulfillment(of: [delivered], timeout: 2)

    XCTAssertEqual(center.requests.count, 2)
    XCTAssertEqual(
      Set(center.requests.map(\.content.body)),
      [String(localized: "Response ready"), String(localized: "Run failed")])
    for request in center.requests {
      XCTAssertEqual(request.content.title, "Munie")
      XCTAssertFalse(request.content.title.contains("PRIVATE"))
      XCTAssertFalse(request.content.body.contains("PRIVATE"))
      XCTAssertEqual(request.content.userInfo["threadId"] as? String, "thread")
    }
  }

  func testStructuredInputNotificationDoesNotExposePrivateThreadTitleOrQuestion() async {
    let center = ApprovalNotificationCenter()
    let service = makeService(center)
    service.threads = [CodexThread(id: "thread", title: "PRIVATE_CUSTOMER_INCIDENT")]
    let delivered = expectation(description: "generic question alert")
    center.onAdd = { delivered.fulfill() }
    service.notifyStructuredUserInputIfNeeded(
      threadId: "thread", turnId: "turn", requestID: .string("question"),
      questions: [
        CodexStructuredUserInputQuestion(
          id: "question", header: "PRIVATE_HEADER", question: "PRIVATE_QUESTION",
          isOther: false, isSecret: true, options: [])
      ])
    await fulfillment(of: [delivered], timeout: 2)

    XCTAssertEqual(center.requests.count, 1)
    guard let content = center.requests.first?.content else { return XCTFail("Missing alert") }
    XCTAssertEqual(content.title, "Munie")
    XCTAssertEqual(content.body, String(localized: "Codex needs one answer to continue."))
    XCTAssertFalse(content.title.contains("PRIVATE"))
    XCTAssertFalse(content.body.contains("PRIVATE"))
    XCTAssertEqual(content.userInfo["threadId"] as? String, "thread")
  }

  func testCommandAndFileApprovalsNotifyWithoutPrivateCommandOrReason() async throws {
    let center = ApprovalNotificationCenter()
    let service = makeService(center)
    for (index, method) in [
      "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
    ].enumerated() {
      service.handleServerRequest(
        method: method, requestID: .string("approval-\(index)"),
        params: .object([
          "threadId": .string("thread-\(index)"), "turnId": .string("turn-\(index)"),
          "command": .string("PRIVATE_COMMAND"), "reason": .string("PRIVATE_REASON"),
        ]))
    }
    for request in service.pendingApprovals {
      await service.notifyPendingApprovalIfNeeded(request)?.value
    }

    XCTAssertEqual(center.requests.count, 2)
    for request in center.requests {
      XCTAssertEqual(request.content.title, String(localized: "Approval required"))
      XCTAssertEqual(
        request.content.body, String(localized: "Open Munie to review a pending approval."))
      XCTAssertFalse(request.content.body.contains("PRIVATE"))
      XCTAssertEqual(
        Set(request.content.userInfo.keys.compactMap { $0 as? String }),
        ["source", "threadId", "turnId", "requestId"])
      XCTAssertEqual(request.content.userInfo["source"] as? String, "codex.approvalRequest")
    }
  }

  func testRepeatedPendingApprovalAndSameRequestAfterRecreationNotifyOnce() async {
    let center = ApprovalNotificationCenter()
    let suiteName = "MunieApprovalNotificationTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    let service = makeService(center, defaults: defaults)
    let request = makeRequest()
    service.pendingApprovals = [request]
    await service.notifyPendingApprovalIfNeeded(request)?.value
    await service.notifyPendingApprovalIfNeeded(request)?.value
    let reopened = makeService(center, defaults: defaults)
    reopened.pendingApprovals = [request]
    await reopened.notifyPendingApprovalIfNeeded(request)?.value
    XCTAssertEqual(center.requests.count, 1)
  }

  func testForegroundReplayDeniedAndTerminalRequestsDoNotNotify() async {
    let center = ApprovalNotificationCenter()
    let service = makeService(center)
    let request = makeRequest()
    service.pendingApprovals = [request]
    service.isAppInForeground = true
    service.applicationStateProvider = { .active }
    XCTAssertNil(service.notifyPendingApprovalIfNeeded(request))
    service.isAppInForeground = false
    service.applicationStateProvider = { .background }
    service.isApplyingReplayedBridgeEvent = true
    XCTAssertNil(service.notifyPendingApprovalIfNeeded(request))
    service.isApplyingReplayedBridgeEvent = false
    center.status = .denied
    await service.notifyPendingApprovalIfNeeded(request)?.value
    center.status = .authorized
    service.recordTurnTerminalState(threadId: "thread", turnId: "turn", state: .completed)
    await service.notifyPendingApprovalIfNeeded(request)?.value
    XCTAssertTrue(center.requests.isEmpty)
  }

  func testApprovalResolvedDuringAuthorizationReadDoesNotNotify() async {
    let center = ApprovalNotificationCenter()
    let service = makeService(center)
    let request = makeRequest()
    service.pendingApprovals = [request]
    let authorizationStarted = expectation(description: "authorization read started")
    center.onAuthorization = { authorizationStarted.fulfill() }
    center.suspendsAuthorization = true
    let task = service.notifyPendingApprovalIfNeeded(request)
    await fulfillment(of: [authorizationStarted], timeout: 1)
    service.removePendingApproval(requestID: request.requestID)
    center.resumeAuthorization()
    await task?.value
    XCTAssertTrue(center.requests.isEmpty)
  }

  func testMacContextChangedDuringAuthorizationReadDoesNotNotify() async {
    let center = ApprovalNotificationCenter()
    let service = makeService(center)
    let request = makeRequest()
    service.pendingApprovals = [request]
    let authorizationStarted = expectation(description: "authorization read started")
    center.onAuthorization = { authorizationStarted.fulfill() }
    center.suspendsAuthorization = true
    let task = service.notifyPendingApprovalIfNeeded(request)
    await fulfillment(of: [authorizationStarted], timeout: 1)
    service.currentTrustedMacDeviceId = "another-mac"
    center.resumeAuthorization()
    await task?.value
    XCTAssertTrue(center.requests.isEmpty)
  }

  func testNotificationTapRoutesToExactThreadWithoutAnsweringApproval() async {
    let center = ApprovalNotificationCenter()
    let service = makeService(center)
    let request = makeRequest()
    service.pendingApprovals = [request]
    service.threads = [CodexThread(id: "thread", title: "Task")]
    await service.notifyPendingApprovalIfNeeded(request)?.value
    guard let content = center.requests.first?.content else { return XCTFail("Missing alert") }
    service.handleNotificationOpen(userInfo: content.userInfo)
    let routed = await service.routePendingNotificationOpenIfPossible(refreshIfNeeded: false)
    XCTAssertTrue(routed)
    XCTAssertEqual(service.activeThreadId, "thread")
    XCTAssertEqual(service.pendingApprovals.map(\.id), [request.id])
    XCTAssertNil(service.pendingNotificationOpenThreadID)
  }

  func testFailedSystemSchedulingCanRetrySamePendingApproval() async {
    let center = ApprovalNotificationCenter()
    center.failsAdd = true
    let service = makeService(center)
    let request = makeRequest()
    service.pendingApprovals = [request]
    await service.notifyPendingApprovalIfNeeded(request)?.value
    center.failsAdd = false
    await service.notifyPendingApprovalIfNeeded(request)?.value
    XCTAssertEqual(center.requests.count, 1)
  }

  private func makeRequest() -> CodexApprovalRequest {
    CodexApprovalRequest(
      id: "s:approval", requestID: .string("approval"),
      method: "item/commandExecution/requestApproval", command: "PRIVATE_COMMAND",
      reason: "PRIVATE_REASON", threadId: "thread", turnId: "turn", params: nil)
  }

  private func makeService(
    _ center: ApprovalNotificationCenter, defaults providedDefaults: UserDefaults? = nil
  ) -> CodexService {
    let suiteName = "MunieApprovalNotificationTests.\(UUID())"
    let defaults = providedDefaults ?? UserDefaults(suiteName: suiteName)!
    let service = CodexService(defaults: defaults, userNotificationCenter: center)
    service.currentTrustedMacDeviceId = "approval-fixture-mac"
    service.relaySessionId = "approval-fixture-session"
    service.selectedAccessMode = .onRequest
    service.isAppInForeground = false
    service.applicationStateProvider = { .background }
    service.messagesByThread = [:]
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    services.append(service)
    return service
  }
}

@MainActor
private final class ApprovalNotificationCenter: CodexUserNotificationCentering {
  var delegate: UNUserNotificationCenterDelegate?
  var status: UNAuthorizationStatus = .authorized
  var requests: [UNNotificationRequest] = []
  var failsAdd = false
  var suspendsAuthorization = false
  var onAuthorization: (() -> Void)?
  var onAdd: (() -> Void)?
  private var continuation: CheckedContinuation<UNAuthorizationStatus, Never>?

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }

  func authorizationStatus() async -> UNAuthorizationStatus {
    if suspendsAuthorization {
      return await withCheckedContinuation { continuation in
        self.continuation = continuation
        onAuthorization?()
      }
    }
    return status
  }

  func resumeAuthorization() {
    suspendsAuthorization = false
    continuation?.resume(returning: status)
    continuation = nil
  }

  func add(_ request: UNNotificationRequest) async throws {
    if failsAdd { throw NSError(domain: "ApprovalNotificationFixture", code: 1) }
    requests.append(request)
    onAdd?()
  }
}
