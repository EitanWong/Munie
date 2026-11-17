// Munie modification: test module renamed from CodexMobile.
// FILE: SidebarThreadsLoadingPresentationTests.swift
// Purpose: Guards sidebar loading presentation so pull-to-refresh does not show a duplicate spinner.
// Layer: Unit Test
// Exports: SidebarThreadsLoadingPresentationTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import MunieRemodex

final class SidebarThreadsLoadingPresentationTests: XCTestCase {
    func testShowsOverlayWhenInitialThreadLoadIsInFlight() {
        let shouldShow = SidebarThreadsLoadingPresentation.shouldShowOverlay(
            isLoadingThreads: true,
            threadCount: 0
        )

        XCTAssertTrue(shouldShow)
    }

    func testHidesOverlayWhenRefreshingExistingThreads() {
        let shouldShow = SidebarThreadsLoadingPresentation.shouldShowOverlay(
            isLoadingThreads: true,
            threadCount: 3
        )

        XCTAssertFalse(shouldShow)
    }
}
