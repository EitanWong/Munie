// Munie modification: test module renamed from CodexMobile.
// FILE: TurnComposerAttachmentIntakePlanTests.swift
// Purpose: Verifies attachment slot limiting and overflow behavior for the refactored composer.
// Layer: Unit Test
// Exports: TurnComposerAttachmentIntakePlanTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import MunieRemodex

final class TurnComposerAttachmentIntakePlanTests: XCTestCase {
    // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
    nonisolated deinit {}

    func testIntakePlanAcceptsAllWhenWithinRemainingSlots() {
        let plan = TurnComposerAttachmentIntakePlan.make(requestedCount: 2, remainingSlots: 4)

        XCTAssertEqual(plan.acceptedCount, 2)
        XCTAssertEqual(plan.droppedCount, 0)
        XCTAssertFalse(plan.hasOverflow)
    }

    func testIntakePlanDropsOverflowingItems() {
        let plan = TurnComposerAttachmentIntakePlan.make(requestedCount: 6, remainingSlots: 4)

        XCTAssertEqual(plan.acceptedCount, 4)
        XCTAssertEqual(plan.droppedCount, 2)
        XCTAssertTrue(plan.hasOverflow)
    }

    func testIntakePlanDropsAllWhenNoRemainingSlots() {
        let plan = TurnComposerAttachmentIntakePlan.make(requestedCount: 3, remainingSlots: 0)

        XCTAssertEqual(plan.acceptedCount, 0)
        XCTAssertEqual(plan.droppedCount, 3)
        XCTAssertTrue(plan.hasOverflow)
    }

}
