// Munie modification: declare existing throwing XCTest unwrap failures without changing assertions.
// Munie modification: test module renamed from CodexMobile.
// FILE: AIChangeSetTests.swift
// Purpose: Verifies patch parsing and turn-scoped AI change-set finalization for revertable responses.
// Layer: Unit Test
// Exports: AIChangeSetTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import MunieRemodex

@MainActor
final class AIChangeSetTests: XCTestCase {
    // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
    nonisolated deinit {}

    func testUnifiedPatchParserExtractsSingleFileUpdate() {
        let patch = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,2 +1,3 @@
         struct App {}
        +let enabled = true
        -let disabled = false
        """

        let analysis = AIUnifiedPatchParser.analyze(patch)

        XCTAssertEqual(analysis.fileChanges.count, 1)
        XCTAssertEqual(analysis.fileChanges.first?.path, "Sources/App.swift")
        XCTAssertEqual(analysis.fileChanges.first?.kind, .update)
        XCTAssertEqual(analysis.fileChanges.first?.additions, 1)
        XCTAssertEqual(analysis.fileChanges.first?.deletions, 1)
        XCTAssertTrue(analysis.unsupportedReasons.isEmpty)
    }

    func testUnifiedPatchParserMarksRenameAsUnsupported() {
        let patch = """
        diff --git a/Old.swift b/New.swift
        similarity index 100%
        rename from Old.swift
        rename to New.swift
        """

        let analysis = AIUnifiedPatchParser.analyze(patch)

        XCTAssertTrue(analysis.fileChanges.isEmpty)
        XCTAssertTrue(
            analysis.unsupportedReasons.contains("Rename, mode-only, or symlink changes are not auto-revertable in v1.")
        )
    }

    func testTurnDiffFinalizesReadyChangeSetForAssistantMessage() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "Revert", cwd: "/tmp/repo")
        ]

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Implemented the change."
        )
        service.recordTurnDiffChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1111111..2222222 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1 +1,2 @@
             struct App {}
            +let enabled = true
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: assistantMessage))

        XCTAssertEqual(changeSet.threadId, threadID)
        XCTAssertEqual(changeSet.turnId, turnID)
        XCTAssertEqual(changeSet.assistantMessageId, assistantMessage.id)
        XCTAssertEqual(changeSet.status, .ready)
        XCTAssertEqual(changeSet.repoRoot, "/tmp/repo")
    }

    func testProjectedTurnChangeSetsStaySeparateAcrossThreads() throws {
        let service = makeService()
        let firstThreadID = "thread-first"
        let secondThreadID = "thread-second"
        let projectedTurnID = "ipc-turn-0"
        service.threads = [
            CodexThread(id: firstThreadID, title: "First", cwd: "/tmp/first-repo"),
            CodexThread(id: secondThreadID, title: "Second", cwd: "/tmp/second-repo"),
        ]

        service.completeAssistantMessage(
            threadId: firstThreadID,
            turnId: projectedTurnID,
            itemId: nil,
            text: "Changed the first repository."
        )
        service.recordTurnDiffChangeSet(
            threadId: firstThreadID,
            turnId: projectedTurnID,
            diff: """
            diff --git a/Sources/First.swift b/Sources/First.swift
            index 1111111..2222222 100644
            --- a/Sources/First.swift
            +++ b/Sources/First.swift
            @@ -1 +1,2 @@
             struct First {}
            +let firstOnly = true
            """
        )

        service.completeAssistantMessage(
            threadId: secondThreadID,
            turnId: projectedTurnID,
            itemId: nil,
            text: "Changed the second repository."
        )
        service.recordTurnDiffChangeSet(
            threadId: secondThreadID,
            turnId: projectedTurnID,
            diff: """
            diff --git a/Sources/Second.swift b/Sources/Second.swift
            index 3333333..4444444 100644
            --- a/Sources/Second.swift
            +++ b/Sources/Second.swift
            @@ -1 +1,2 @@
             struct Second {}
            +let secondOnly = true
            """
        )

        service.recordTurnTerminalState(
            threadId: firstThreadID,
            turnId: projectedTurnID,
            state: .completed
        )
        service.noteTurnFinished(threadId: firstThreadID, turnId: projectedTurnID)
        service.recordTurnTerminalState(
            threadId: secondThreadID,
            turnId: projectedTurnID,
            state: .completed
        )
        service.noteTurnFinished(threadId: secondThreadID, turnId: projectedTurnID)

        let firstAssistant = try XCTUnwrap(
            service.messages(for: firstThreadID).last(where: { $0.role == .assistant })
        )
        let secondAssistant = try XCTUnwrap(
            service.messages(for: secondThreadID).last(where: { $0.role == .assistant })
        )
        // Exercise the turn-scoped assistant fallback rather than the primary
        // assistant-message index, which already has globally stable IDs.
        service.aiChangeSetIDByAssistantMessageID.removeAll()
        let firstChangeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: firstAssistant))
        let secondChangeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: secondAssistant))

        XCTAssertNotEqual(firstChangeSet.id, secondChangeSet.id)
        XCTAssertEqual(firstChangeSet.threadId, firstThreadID)
        XCTAssertEqual(secondChangeSet.threadId, secondThreadID)
        XCTAssertEqual(firstChangeSet.repoRoot, "/tmp/first-repo")
        XCTAssertEqual(secondChangeSet.repoRoot, "/tmp/second-repo")
        XCTAssertTrue(firstChangeSet.forwardUnifiedPatch.contains("firstOnly"))
        XCTAssertFalse(firstChangeSet.forwardUnifiedPatch.contains("secondOnly"))
        XCTAssertTrue(secondChangeSet.forwardUnifiedPatch.contains("secondOnly"))
        XCTAssertFalse(secondChangeSet.forwardUnifiedPatch.contains("firstOnly"))
        XCTAssertEqual(service.aiChangeSetIDByTurnKey.count, 2)
    }

    func testWorkspaceCheckpointSupersedesRuntimeDiffWhenFileScopeMatches() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Implemented the change."
        )
        service.recordTurnDiffChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/Runtime.swift b/Sources/Runtime.swift
            index 1111111..2222222 100644
            --- a/Sources/Runtime.swift
            +++ b/Sources/Runtime.swift
            @@ -1 +1,2 @@
             struct Runtime {}
            +let fromRuntime = true
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)
        service.recordWorkspaceCheckpointChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/Runtime.swift b/Sources/Runtime.swift
            index 3333333..4444444 100644
            --- a/Sources/Runtime.swift
            +++ b/Sources/Runtime.swift
            @@ -1 +1,2 @@
             struct Runtime {}
            +let fromCheckpoint = true
            """
        )

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: assistantMessage))

        XCTAssertEqual(changeSet.source, .workspaceCheckpoint)
        XCTAssertEqual(changeSet.fileChanges.map(\.path), ["Sources/Runtime.swift"])
        XCTAssertFalse(changeSet.forwardUnifiedPatch.contains("fromRuntime"))
        XCTAssertTrue(changeSet.forwardUnifiedPatch.contains("fromCheckpoint"))
    }

    func testWorkspaceCheckpointCapturesWiderFilesystemChangesThanRuntimeDiff() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Implemented the change."
        )
        service.recordTurnDiffChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             struct A {}
            +let fromRuntime = true
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)
        service.recordWorkspaceCheckpointChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             struct A {}
            +let fromRuntime = true
            diff --git a/Sources/B.swift b/Sources/B.swift
            index 3333333..4444444 100644
            --- a/Sources/B.swift
            +++ b/Sources/B.swift
            @@ -1 +1,2 @@
             struct B {}
            +let userOrBridgeChange = true
            """
        )

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: assistantMessage))

        XCTAssertEqual(changeSet.source, .workspaceCheckpoint)
        XCTAssertEqual(changeSet.fileChanges.map(\.path), ["Sources/A.swift", "Sources/B.swift"])
        XCTAssertTrue(changeSet.forwardUnifiedPatch.contains("Sources/B.swift"))
    }

    func testLateRuntimeDiffDoesNotReplaceAuthoritativeWorkspaceCheckpoint() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Implemented the change."
        )
        service.recordWorkspaceCheckpointChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             struct A {}
            +let checkpointChange = true
            diff --git a/Sources/B.swift b/Sources/B.swift
            index 3333333..4444444 100644
            --- a/Sources/B.swift
            +++ b/Sources/B.swift
            @@ -1 +1,2 @@
             struct B {}
            +let userOrBridgeChange = true
            """
        )
        service.recordTurnDiffChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             struct A {}
            +let runtimeChange = true
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: assistantMessage))

        XCTAssertEqual(changeSet.source, .workspaceCheckpoint)
        XCTAssertEqual(changeSet.fileChanges.map(\.path), ["Sources/A.swift", "Sources/B.swift"])
        XCTAssertFalse(changeSet.forwardUnifiedPatch.contains("runtimeChange"))
        XCTAssertTrue(changeSet.forwardUnifiedPatch.contains("checkpointChange"))
        XCTAssertTrue(changeSet.forwardUnifiedPatch.contains("Sources/B.swift"))
    }

    func testOrderedFallbackPatchesAreReadyAndPreviewedInReverseOrder() async throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Made several edits."
        )
        service.recordFallbackFileChangePatch(
            threadId: threadID,
            turnId: turnID,
            patch: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             let a = 1
            +let b = 2
            """
        )
        service.recordFallbackFileChangePatch(
            threadId: threadID,
            turnId: turnID,
            patch: """
            diff --git a/Sources/B.swift b/Sources/B.swift
            index 3333333..4444444 100644
            --- a/Sources/B.swift
            +++ b/Sources/B.swift
            @@ -1 +1,2 @@
             let c = 3
            +let d = 4
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = try XCTUnwrap(service.aiChangeSet(forAssistantMessage: assistantMessage))

        XCTAssertEqual(changeSet.status, .ready)
        XCTAssertTrue(changeSet.unsupportedReasons.isEmpty)
        XCTAssertEqual(changeSet.fallbackPatchBatches.count, 2)
        XCTAssertEqual(changeSet.fallbackPatchBatches.flatMap(\.fileChanges).map(\.path), ["Sources/A.swift", "Sources/B.swift"])
        var previewPatches: [String] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "workspace/revertPatchBatchPreview")
            previewPatches = params?.objectValue?["patches"]?.arrayValue?.compactMap {
                $0.objectValue?["forwardPatch"]?.stringValue
            } ?? []
            return RPCMessage(id: .string(UUID().uuidString), result: .object(["canRevert": .bool(true)]), includeJSONRPC: false)
        }
        let preview = try await service.previewRevert(changeSet: changeSet, workingDirectory: "/tmp/repo")
        XCTAssertTrue(preview.canRevert)
        XCTAssertEqual(previewPatches, changeSet.fallbackPatchBatches.reversed().map(\.forwardUnifiedPatch))
    }

    func testAssistantRevertPresentationIsSafeForDistinctFilesInSameRepo() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let siblingThreadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "Revert", cwd: "/tmp/repo"),
            CodexThread(id: siblingThreadID, title: "Sibling", cwd: "/tmp/repo")
        ]

        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "Sources/App.swift"
        )
        _ = recordReadyChangeSet(
            service: service,
            threadID: siblingThreadID,
            filePath: "README.md"
        )

        let presentation = try XCTUnwrap(
            service.assistantRevertPresentation(for: assistantMessage, workingDirectory: "/tmp/repo")
        )

        XCTAssertEqual(presentation.riskLevel, .safe)
        XCTAssertTrue(presentation.isEnabled)
        XCTAssertTrue(presentation.overlappingFiles.isEmpty)
    }

    func testAssistantRevertPresentationWarnsWhenSiblingTouchesSameFile() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let siblingThreadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "Revert", cwd: "/tmp/repo"),
            CodexThread(id: siblingThreadID, title: "Sibling", cwd: "/tmp/repo")
        ]

        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "Sources/App.swift"
        )
        _ = recordReadyChangeSet(
            service: service,
            threadID: siblingThreadID,
            filePath: "Sources/App.swift"
        )

        let presentation = try XCTUnwrap(
            service.assistantRevertPresentation(for: assistantMessage, workingDirectory: "/tmp/repo")
        )

        XCTAssertEqual(presentation.riskLevel, .warning)
        XCTAssertTrue(presentation.isEnabled)
        XCTAssertEqual(presentation.overlappingFiles, ["Sources/App.swift"])
    }

    func testAssistantRevertPresentationBlocksWhileSiblingRunIsStillActive() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let siblingThreadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "Revert", cwd: "/tmp/repo"),
            CodexThread(id: siblingThreadID, title: "Sibling", cwd: "/tmp/repo")
        ]

        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "Sources/App.swift"
        )

        service.markThreadAsRunning(siblingThreadID)

        let presentation = try XCTUnwrap(
            service.assistantRevertPresentation(for: assistantMessage, workingDirectory: "/tmp/repo")
        )

        XCTAssertEqual(presentation.riskLevel, .blocked)
        XCTAssertFalse(presentation.isEnabled)
        XCTAssertEqual(
            presentation.helperText,
            "Finish the active run in this repo before undoing this response."
        )
    }

    func testTimelineSnapshotInvalidatesWarningWhenSiblingChangeSetBecomesReverted() async throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let siblingThreadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "Revert", cwd: "/tmp/repo"),
            CodexThread(id: siblingThreadID, title: "Sibling", cwd: "/tmp/repo")
        ]

        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "Sources/App.swift"
        )
        let siblingMessage = recordReadyChangeSet(
            service: service,
            threadID: siblingThreadID,
            filePath: "Sources/App.swift"
        )

        XCTAssertEqual(
            service.timelineState(for: threadID).renderSnapshot.assistantRevertStatesByMessageID[assistantMessage.id]?.riskLevel,
            .warning
        )

        let siblingChangeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: siblingMessage))
        var revertedChangeSet = siblingChangeSet
        revertedChangeSet.status = .reverted
        service.aiChangeSetsByID[siblingChangeSet.id] = revertedChangeSet
        service.invalidateAssistantRevertStates()
        await service.coalescedRevertRefreshTask?.value

        XCTAssertEqual(
            service.timelineState(for: threadID).renderSnapshot.assistantRevertStatesByMessageID[assistantMessage.id]?.riskLevel,
            .safe
        )
    }

    func testKnownRepoRootImmediatelyRecognizesSiblingSubdirectories() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let siblingThreadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "App", cwd: "/tmp/repo/app"),
            CodexThread(id: siblingThreadID, title: "Docs", cwd: "/tmp/repo/docs")
        ]

        service.rememberRepoRoot("/tmp/repo", forWorkingDirectory: "/tmp/repo/docs")
        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "README.md"
        )
        _ = recordReadyChangeSet(
            service: service,
            threadID: siblingThreadID,
            filePath: "README.md"
        )

        XCTAssertEqual(
            service.timelineState(for: threadID).renderSnapshot.assistantRevertStatesByMessageID[assistantMessage.id]?.riskLevel,
            .warning
        )

        service.rememberRepoRoot("/tmp/repo", forWorkingDirectory: "/tmp/repo/app")

        XCTAssertEqual(
            service.timelineState(for: threadID).renderSnapshot.assistantRevertStatesByMessageID[assistantMessage.id]?.riskLevel,
            .warning
        )
    }

    func testAssistantRevertPresentationBlocksWhenWorkingDirectoryIsMissing() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "Sources/App.swift"
        )

        let presentation = try XCTUnwrap(
            service.assistantRevertPresentation(for: assistantMessage, workingDirectory: nil)
        )

        XCTAssertEqual(presentation.riskLevel, .blocked)
        XCTAssertFalse(presentation.isEnabled)
    }

    func testAssistantRevertPresentationBlocksLegacyUnorderedFallbackResponse() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Made several edits."
        )
        service.recordFallbackFileChangePatch(
            threadId: threadID,
            turnId: turnID,
            patch: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             let a = 1
            +let b = 2
            """
        )
        service.recordFallbackFileChangePatch(
            threadId: threadID,
            turnId: turnID,
            patch: """
            diff --git a/Sources/B.swift b/Sources/B.swift
            index 3333333..4444444 100644
            --- a/Sources/B.swift
            +++ b/Sources/B.swift
            @@ -1 +1,2 @@
             let c = 3
            +let d = 4
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        var legacy = try XCTUnwrap(service.aiChangeSet(forAssistantMessage: assistantMessage))
        legacy.fallbackPatchBatches = []
        legacy.fallbackPatchCount = 2
        legacy.status = .collecting
        service.aiChangeSetsByID[legacy.id] = legacy
        service.noteTurnFinished(threadId: threadID, turnId: turnID)
        let presentation = try XCTUnwrap(
            service.assistantRevertPresentation(for: assistantMessage, workingDirectory: "/tmp/repo")
        )

        XCTAssertEqual(presentation.riskLevel, .blocked)
        XCTAssertFalse(presentation.isEnabled)
        XCTAssertEqual(service.aiChangeSet(forAssistantMessage: assistantMessage)?.status, .notRevertable)
        XCTAssertTrue(presentation.helperText?.contains("before ordered patch batches were stored") == true)
    }

    func testArchiveThreadPrunesCachedTimelineState() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        service.threads = [
            CodexThread(id: threadID, title: "Archive Me", cwd: "/tmp/repo")
        ]

        service.appendSystemMessage(
            threadId: threadID,
            text: "Status: completed\n\nPath: Sources/App.swift\nKind: update\nTotals: +1 -0",
            kind: .fileChange
        )
        _ = service.timelineState(for: threadID)

        XCTAssertNotNil(service.threadTimelineStateByThread[threadID])

        service.archiveThread(threadID)
        service.refreshAllThreadTimelineStates()

        XCTAssertNil(service.threadTimelineStateByThread[threadID])
        XCTAssertNil(service.latestRepoAffectingMessageSignalByThread[threadID])
        XCTAssertNil(service.stoppedTurnIDsByThread[threadID])
    }

    // Creates a finalized, undoable response fixture with one changed file.
    @discardableResult
    private func recordReadyChangeSet(
        service: CodexService,
        threadID: String,
        filePath: String
    ) -> CodexMessage {
        let turnID = "turn-\(UUID().uuidString)"
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Implemented the change."
        )
        service.recordTurnDiffChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/\(filePath) b/\(filePath)
            index 1111111..2222222 100644
            --- a/\(filePath)
            +++ b/\(filePath)
            @@ -1 +1,2 @@
             struct App {}
            +let enabled = true
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        // The real turn/completed handler clears lifecycle state before finalizing the ledger.
        service.clearRunningState(for: threadID)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)
        return try! XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
    }

    private func makeService() -> CodexService {
        let suiteName = "AIChangeSetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let service = CodexService(defaults: defaults)
        let fixtureMacID = "ai-changeset-fixture-\(UUID().uuidString)"
        service.currentTrustedMacDeviceId = fixtureMacID
        service.loadMacScopedAIChangeSets(for: fixtureMacID)
        service.messagesByThread = [:]
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            XCTAssertTrue(AIChangeSetPersistence().delete(macDeviceId: fixtureMacID))
        }
        Self.retainedServices.append(service)
        return service
    }

    private static var retainedServices: [CodexService] = []

    override func tearDown() async throws {
        await MunieTestServiceLifecycle.finish(Self.retainedServices)
        Self.retainedServices.removeAll()
        try await super.tearDown()
    }
}
