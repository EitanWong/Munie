// FILE: CodexServiceUnconfirmedHistoryTests.swift
// Purpose: Verifies that history can confirm an unknown send only by canonical identity.

import Foundation
import XCTest

@testable import MunieRemodex

final class CodexServiceUnconfirmedHistoryTests: XCTestCase {
  func testCanonicalMatchConfirmsOriginalRowWithoutCoalescingOlderEqualPrompt() throws {
    let local = prompt("local", turnID: "turn-current", delivery: .unconfirmed)
    let old = prompt("old", turnID: "turn-previous", itemID: "item-previous")
    let exact = prompt("exact", turnID: "turn-current", itemID: "item-current")

    let merged = try merge([local], history: [old, exact])

    XCTAssertEqual(merged.count, 2)
    XCTAssertEqual(merged.first(where: { $0.id == old.id })?.itemId, old.itemId)
    let confirmed = try XCTUnwrap(merged.first(where: { $0.id == local.id }))
    XCTAssertEqual(confirmed.deliveryState, .confirmed)
    XCTAssertEqual(confirmed.turnId, exact.turnId)
    XCTAssertEqual(confirmed.itemId, exact.itemId)
  }

  func testUnboundUnconfirmedPromptStaysSeparateFromCanonicalOrTurnlessHistory() throws {
    let local = prompt("local", delivery: .unconfirmed)
    for history in [
      prompt("old", turnID: "turn-previous", itemID: "item-previous"),
      prompt("turnless"),
    ] {
      try assertUnchangedAndSeparate(local, from: history)
    }
  }

  func testProvisionalTurnCannotConfirmOrAcquireCanonicalIdentityFromEqualPrompt() throws {
    let local = prompt(
      "local", turnID: "ipc-turn-0", itemID: "ipc-turn-0:input", sourceKey: "mirror",
      delivery: .unconfirmed)
    for history in [
      prompt("canonical", turnID: "turn-previous", itemID: "item-previous"),
      prompt("mirror", turnID: "ipc-turn-0", itemID: "ipc-turn-0:input", sourceKey: "mirror"),
    ] {
      try assertUnchangedAndSeparate(local, from: history)
    }
  }

  func testCompanionRowsCannotLendTheirCanonicalTurnToAnUnconfirmedPrompt() throws {
    let local = prompt("local", turnID: "ipc-turn-0", delivery: .unconfirmed)
    let opener = prompt("opener", text: "Open the chat", turnID: "ipc-turn-0")
    let canonicalOpener = prompt(
      "canonical-opener", text: opener.text, turnID: "turn-previous", itemID: "item-opener")
    let equalHistory = prompt("equal", turnID: "turn-previous", itemID: "item-equal")

    let merged = try merge([opener, local], history: [canonicalOpener, equalHistory])

    XCTAssertEqual(merged.first(where: { $0.id == opener.id })?.turnId, canonicalOpener.turnId)
    XCTAssertEqual(merged.first(where: { $0.id == local.id })?.turnId, local.turnId)
    XCTAssertEqual(merged.first(where: { $0.id == local.id })?.deliveryState, .unconfirmed)
    XCTAssertNotNil(merged.first(where: { $0.id == equalHistory.id }))
  }

  func testRealTurnAloneDoesNotMakeProvisionalHistoryItemAuthoritative() throws {
    let local = prompt("local", turnID: "turn-current", delivery: .unconfirmed)
    for history in [
      prompt("no-item", turnID: "turn-current"),
      prompt("line-fallback", turnID: "turn-current", itemID: "user-message-line-3"),
      prompt("projected", turnID: "turn-current", itemID: "turn-current:input"),
    ] {
      try assertUnchangedAndSeparate(local, from: history)
    }
  }

  func testConflictingCanonicalIdentityOrPayloadDoesNotConfirm() throws {
    let local = prompt(
      "local", turnID: "turn-current", itemID: "item-current", delivery: .unconfirmed)
    for history in [
      prompt("wrong-turn", turnID: "turn-previous", itemID: "item-current"),
      prompt("wrong-item", turnID: "turn-current", itemID: "item-other"),
      prompt(
        "wrong-text", text: "Different prompt", turnID: "turn-current", itemID: "item-current"),
      prompt(
        "extra-image", turnID: "turn-current", itemID: "item-current",
        attachments: [
          CodexImageAttachment(thumbnailBase64JPEG: "different-image")
        ]),
    ] {
      try assertUnchangedAndSeparate(local, from: history)
    }
  }

  func testItemlessLocalRowIsNotConfirmedWhenCanonicalPageHasMultipleMatchingItems() throws {
    let local = prompt("local", turnID: "turn-current", delivery: .unconfirmed)
    let first = prompt("first", turnID: "turn-current", itemID: "item-first")
    let second = prompt("second", turnID: "turn-current", itemID: "item-second")

    let merged = try merge([local], history: [first, second])

    let unresolved = try XCTUnwrap(merged.first(where: { $0.id == local.id }))
    XCTAssertEqual(unresolved.deliveryState, .unconfirmed)
    XCTAssertNil(unresolved.itemId)
    XCTAssertTrue(merged.contains { $0.deliveryState == .confirmed })
  }

  func testPendingSendStillReconcilesWithoutPreboundTurn() throws {
    let local = prompt("local", delivery: .pending)
    let history = prompt("canonical", turnID: "turn-current", itemID: "item-current")

    let merged = try merge([local], history: [history])

    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged.first?.id, local.id)
    XCTAssertEqual(merged.first?.deliveryState, .confirmed)
    XCTAssertEqual(merged.first?.turnId, history.turnId)
  }

  private func assertUnchangedAndSeparate(
    _ local: CodexMessage,
    from history: CodexMessage,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let merged = try merge([local], history: [history])
    XCTAssertEqual(merged.count, 2, file: file, line: line)
    XCTAssertTrue(merged.contains { $0.id == history.id }, file: file, line: line)
    let unresolved = try XCTUnwrap(
      merged.first(where: { $0.id == local.id }), file: file, line: line)
    XCTAssertEqual(unresolved.deliveryState, .unconfirmed, file: file, line: line)
    XCTAssertEqual(unresolved.turnId, local.turnId, file: file, line: line)
    XCTAssertEqual(unresolved.itemId, local.itemId, file: file, line: line)
    XCTAssertEqual(unresolved.text, local.text, file: file, line: line)
  }

  private func merge(_ local: [CodexMessage], history: [CodexMessage]) throws -> [CodexMessage] {
    try CodexService.mergeHistoryMessages(local, history, activeThreadIDs: [], runningThreadIDs: [])
  }

  private func prompt(
    _ id: String,
    text: String = "Repeat this prompt",
    turnID: String? = nil,
    itemID: String? = nil,
    sourceKey: String? = nil,
    delivery: CodexMessageDeliveryState = .confirmed,
    attachments: [CodexImageAttachment] = []
  ) -> CodexMessage {
    CodexMessage(
      id: id,
      threadId: "thread-history",
      role: .user,
      text: text,
      turnId: turnID,
      itemId: itemID,
      sourceItemKey: sourceKey,
      deliveryState: delivery,
      attachments: attachments
    )
  }
}
