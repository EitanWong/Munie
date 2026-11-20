// Munie modification: declare throwing XCTest unwrap failure.
// Munie modification: test module renamed from CodexMobile.
// FILE: CodexApprovalStateTests.swift
// Purpose: Verifies approval requests queue safely, clean up on server resolution, and survive failed replies.
// Layer: Unit Test
// Exports: CodexApprovalStateTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import MunieRemodex

@MainActor
final class CodexApprovalStateTests: XCTestCase {
    // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
    nonisolated deinit {}

    private static var retainedServices: [CodexService] = []

    override func tearDown() async throws {
        await MunieTestServiceLifecycle.finish(Self.retainedServices)
        Self.retainedServices.removeAll()
        try await super.tearDown()
    }

    func testIncomingApprovalRequestsQueueWithoutOverwritingDifferentThreads() {
        let service = makeService()
        let firstRequestID: JSONValue = .string("approval-1")
        let secondRequestID: JSONValue = .string("approval-2")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: firstRequestID,
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                    "command": .string("git commit"),
                ]),
                includeJSONRPC: false
            )
        )
        service.handleIncomingRPCMessage(
            RPCMessage(
                id: secondRequestID,
                method: "item/fileChange/requestApproval",
                params: .object([
                    "threadId": .string("thread-b"),
                    "turnId": .string("turn-b"),
                    "reason": .string("Write file"),
                ]),
                includeJSONRPC: false
            )
        )

        XCTAssertEqual(service.pendingApprovals.count, 2)
        XCTAssertEqual(service.pendingApproval(for: "thread-a")?.id, service.idKey(from: firstRequestID))
        XCTAssertEqual(service.pendingApproval(for: "thread-b")?.id, service.idKey(from: secondRequestID))
    }

    func testServerRequestResolvedRemovesOnlyMatchingApproval() {
        let service = makeService()
        let firstRequestID: JSONValue = .string("approval-1")
        let secondRequestID: JSONValue = .string("approval-2")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: firstRequestID,
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                ]),
                includeJSONRPC: false
            )
        )
        service.handleIncomingRPCMessage(
            RPCMessage(
                id: secondRequestID,
                method: "item/fileChange/requestApproval",
                params: .object([
                    "threadId": .string("thread-b"),
                    "turnId": .string("turn-b"),
                ]),
                includeJSONRPC: false
            )
        )

        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "serverRequest/resolved",
                params: .object([
                    "threadId": .string("thread-a"),
                    "requestId": firstRequestID,
                ]),
                includeJSONRPC: false
            )
        )

        XCTAssertEqual(service.pendingApprovals.count, 1)
        XCTAssertNil(service.pendingApproval(for: "thread-a"))
        XCTAssertEqual(service.pendingApproval(for: "thread-b")?.id, service.idKey(from: secondRequestID))
    }

    func testServerRequestResolvedDoesNotRemoveDifferentApprovalFromSameThread() {
        let service = makeService()
        let approvalRequestID: JSONValue = .string("approval-1")
        let structuredInputRequestID: JSONValue = .string("structured-input-1")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: approvalRequestID,
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                ]),
                includeJSONRPC: false
            )
        )

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: structuredInputRequestID,
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                    "questions": .array([
                        .object([
                            "id": .string("question-1"),
                            "header": .string("Question"),
                            "question": .string("Choose one"),
                            "options": .array([
                                .object([
                                    "label": .string("Yes"),
                                    "description": .string("Confirm"),
                                ])
                            ]),
                        ])
                    ]),
                ]),
                includeJSONRPC: false
            )
        )

        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "serverRequest/resolved",
                params: .object([
                    "threadId": .string("thread-a"),
                    "requestId": structuredInputRequestID,
                ]),
                includeJSONRPC: false
            )
        )

        XCTAssertEqual(service.pendingApprovals.count, 1)
        XCTAssertEqual(service.pendingApproval(for: "thread-a")?.id, service.idKey(from: approvalRequestID))
    }

    func testDesktopMirroredApprovalQueuesEvenWhenFullAccessIsSelected() {
        let service = makeService()
        service.setSelectedAccessMode(.fullAccess)
        let requestID: JSONValue = .string("approval-1")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                    "command": .string("git status"),
                    "remodexActionSource": .string("desktop-ipc-action-follower"),
                ]),
                includeJSONRPC: false
            )
        )

        XCTAssertEqual(service.pendingApprovals.count, 1)
        XCTAssertEqual(service.pendingApproval(for: "thread-a")?.id, service.idKey(from: requestID))
    }

    func testNativeCommandApprovalRequiresExplicitDecisionInFullAccess() throws {
        let service = makeService()
        service.setSelectedAccessMode(.fullAccess)
        let requestID: JSONValue = .integer(42)
        let cwd = "/tmp/Project Folder "

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                    "command": .string("git status"),
                    "reason": .string("Inspect the checkout"),
                    "cwd": .string(cwd),
                ]),
                includeJSONRPC: false
            )
        )

        XCTAssertEqual(service.pendingApprovals.count, 1)
        let request = try XCTUnwrap(service.pendingApproval(for: "thread-a"))
        XCTAssertEqual(request.requestID, requestID)
        XCTAssertEqual(request.turnId, "turn-a")
        XCTAssertEqual(request.command, "git status")
        XCTAssertEqual(request.reason, "Inspect the checkout")
        XCTAssertEqual(request.workingDirectory, cwd)
    }

    func testApprovalWorkingDirectoryOmitsMissingBlankAndNonStringValues() {
        let service = makeService()
        let invalidValues: [JSONValue?] = [nil, .string(" \n"), .integer(42)]

        for (index, value) in invalidValues.enumerated() {
            let threadID = "thread-\(index)"
            var params: [String: JSONValue] = ["threadId": .string(threadID)]
            params["cwd"] = value
            service.handleServerRequest(
                method: "item/commandExecution/requestApproval",
                requestID: .string("approval-\(index)"),
                params: .object(params)
            )

            XCTAssertNotNil(service.pendingApproval(for: threadID))
            XCTAssertNil(service.pendingApproval(for: threadID)?.workingDirectory)
        }
    }

    func testFailedApproveKeepsApprovalQueued() async throws {
        let service = makeService()
        let requestID: JSONValue = .string("approval-1")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                    "command": .string("git commit"),
                ]),
                includeJSONRPC: false
            )
        )

        let request = try XCTUnwrap(service.pendingApproval(for: "thread-a"))

        await XCTAssertThrowsErrorAsync(
            try await service.approvePendingRequest(request)
        )
        XCTAssertEqual(service.pendingApprovals.count, 1)
        XCTAssertEqual(service.pendingApproval(for: "thread-a")?.id, request.id)
    }

    func testAdvertisedCommandApprovalRejectsSessionGrantBeforeTransport() async throws {
        let service = makeService()
        service.handleServerRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("one-time"),
            params: .object([
                "threadId": .string("thread-a"),
                "availableDecisions": .array([.string("accept"), .string("acceptForSession")]),
            ])
        )
        let request = try XCTUnwrap(service.pendingApproval(for: "thread-a"))
        do {
            try await service.approvePendingRequest(request, forSession: true)
            XCTFail("A constrained command cannot grant session approval")
        } catch CodexServiceError.invalidInput {
            XCTAssertEqual(service.pendingApproval(for: "thread-a")?.id, request.id)
        } catch {
            XCTFail("Expected rejection before attempting transport, got \(error)")
        }
    }

    func testOneTimeCancelRemainsPendingUntilExactServerResolution() async throws {
        let service = makeService()
        let request = try offerCommand(using: service, decisions: [.string("cancel"), .string("acceptForSession")])
        XCTAssertEqual(request.oneTimeDecisions, [.cancel])
        await XCTAssertThrowsErrorAsync(
            try await service.respondToPendingApproval(request, decision: .decline) { _, _ in
                XCTFail("Unadvertised decisions must not reach transport")
            }
        )
        try await service.respondToPendingApproval(request, decision: .cancel) { message, didSend in
            XCTAssertEqual(message.id, request.requestID)
            XCTAssertEqual(message.result, .object(["decision": .string("cancel")]))
            didSend()
        }
        XCTAssertEqual(service.pendingApproval(for: "thread-a"), request)
        XCTAssertNil(service.actionableApproval(for: "thread-a"))
        XCTAssertTrue(service.isAwaitingApprovalResolution(for: "thread-a"))
        await XCTAssertThrowsErrorAsync(
            try await service.respondToPendingApproval(request, decision: .cancel) { _, _ in
                XCTFail("A submitted decision must not be sent twice")
            }
        )
        service.handleNotification(method: "serverRequest/resolved", params: .object([
            "threadId": .string("thread-a"), "requestId": .integer(42),
        ]))
        XCTAssertEqual(service.pendingApproval(for: "thread-a"), request)
        service.handleNotification(method: "serverRequest/resolved", params: .object([
            "threadId": .string("thread-a"), "requestId": request.requestID,
        ]))
        XCTAssertNil(service.pendingApproval(for: "thread-a"))
        XCTAssertFalse(service.isAwaitingApprovalResolution(for: "thread-a"))
    }

    func testOneTimeReplyRetriesOnlyFailureBeforeTransportAttempt() async throws {
        let service = makeService()
        let request = try offerCommand(using: service, decisions: [.string("accept")])
        await XCTAssertThrowsErrorAsync(
            try await service.respondToPendingApproval(request, decision: .accept) { _, _ in
                throw CodexServiceError.disconnected
            }
        )
        XCTAssertEqual(service.actionableApproval(for: "thread-a"), request)

        await XCTAssertThrowsErrorAsync(
            try await service.respondToPendingApproval(request, decision: .accept) { _, didSend in
                didSend()
                throw CodexServiceError.disconnected
            }
        )
        XCTAssertNil(service.actionableApproval(for: "thread-a"))
        XCTAssertTrue(service.isAwaitingApprovalResolution(for: "thread-a"))
        service.clearPendingApprovals()
        XCTAssertNil(service.pendingApproval(for: "thread-a"))
        XCTAssertFalse(service.isAwaitingApprovalResolution(for: "thread-a"))
    }

    func testOneTimeResolutionArrivingDuringSendCannotRestorePrompt() async throws {
        let service = makeService()
        let request = try offerCommand(using: service, decisions: [.string("accept")])
        await XCTAssertThrowsErrorAsync(
            try await service.respondToPendingApproval(request, decision: .accept) { _, didSend in
                didSend()
                service.handleNotification(method: "serverRequest/resolved", params: .object([
                    "threadId": .string("thread-a"), "requestId": request.requestID,
                ]))
                throw CodexServiceError.disconnected
            }
        )
        XCTAssertNil(service.actionableApproval(for: "thread-a"))
        XCTAssertFalse(service.isAwaitingApprovalResolution(for: "thread-a"))
    }

    func testLegacyCommandApprovalStillSettlesAfterSendingSessionDecision() async throws {
        let service = makeService()
        let request = try offerCommand(using: service, decisions: nil)
        XCTAssertNil(request.oneTimeDecisions)
        try await service.respondToPendingApproval(request, decision: .acceptForSession) { message, didSend in
            XCTAssertEqual(message.result, .object(["decision": .string("acceptForSession")]))
            didSend()
        }
        XCTAssertNil(service.pendingApproval(for: "thread-a"))
    }

    func testApproveTreatsAlreadyResolvedRequestAsCompleted() async {
        let service = makeService()
        let viewModel = TurnViewModel()
        let request = CodexApprovalRequest(
            id: "approval-1",
            requestID: .string("approval-1"),
            method: "item/commandExecution/requestApproval",
            command: "git status",
            reason: nil,
            threadId: "thread-a",
            turnId: "turn-a",
            params: nil
        )

        let didSucceed = await withCheckedContinuation { continuation in
            viewModel.approve(request, codex: service) { didSucceed in
                continuation.resume(returning: didSucceed)
            }
        }

        XCTAssertTrue(didSucceed)
    }

    private func offerCommand(using service: CodexService, decisions: [JSONValue]?) throws -> CodexApprovalRequest {
        var params: [String: JSONValue] = ["threadId": .string("thread-a")]
        params["availableDecisions"] = decisions.map(JSONValue.array)
        service.handleServerRequest(
            method: "item/commandExecution/requestApproval",
            requestID: .string("42"),
            params: .object(params)
        )
        return try XCTUnwrap(service.pendingApproval(for: "thread-a"))
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexApprovalStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)

        Self.retainedServices.append(service)
        return service
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
    }
}
