// Munie modification: test module renamed from CodexMobile.
// FILE: TerminalSelectableTextNormalizerTests.swift
// Purpose: Verifies selectable terminal text cleanup preserves visible grid content.
// Layer: Unit Test
// Exports: TerminalSelectableTextNormalizerTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import MunieRemodex

final class TerminalSelectableTextNormalizerTests: XCTestCase {
    // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
    nonisolated deinit {}

    func testPreservesLeadingIndentationOnFirstContentLine() {
        let normalized = TerminalSelectableTextNormalizer.normalizedText(
            fromLines: ["", "    indented command   ", ""]
        )

        XCTAssertEqual(normalized, "    indented command")
    }

    func testDropsOnlyEmptyEdgeRows() {
        let normalized = TerminalSelectableTextNormalizer.normalizedText(
            fromLines: ["", "first", "", "third", ""]
        )

        XCTAssertEqual(normalized, "first\n\nthird")
    }

    func testKeepsVisualRowBreaksFromWrappedTerminalRows() {
        let normalized = TerminalSelectableTextNormalizer.normalizedText(
            fromLines: ["long output part one", "part two   "]
        )

        XCTAssertEqual(normalized, "long output part one\npart two")
    }
}
