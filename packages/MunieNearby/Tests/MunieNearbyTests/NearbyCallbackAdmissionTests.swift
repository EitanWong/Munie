import Foundation
import XCTest

@testable import MunieNearby

final class NearbyCallbackAdmissionTests: XCTestCase {
  func testPendingBudgetIsCheckedBeforeTasksCanBeScheduled() throws {
    let source = NSObject()
    let gate = NearbyCallbackAdmission(maximumPending: 2)
    gate.activate(source)
    let first = try XCTUnwrap(gate.admit(source))
    _ = try XCTUnwrap(gate.admit(source))
    for _ in 0..<1_000 { XCTAssertNil(gate.admit(source)) }
    gate.release(first)
    XCTAssertNotNil(gate.admit(source))
  }

  func testOldSourcesAndReleaseTokensCannotAffectTheNextGeneration() throws {
    let oldSource = NSObject()
    let newSource = NSObject()
    let gate = NearbyCallbackAdmission(maximumPending: 1)
    gate.activate(oldSource)
    let stale = try XCTUnwrap(gate.admit(oldSource))
    gate.invalidate()
    XCTAssertNil(gate.admit(oldSource))
    gate.activate(newSource)
    XCTAssertNil(gate.admit(oldSource))
    XCTAssertNotNil(gate.admit(newSource))
    gate.release(stale)
    XCTAssertNil(gate.admit(newSource))
  }

  func testInvitationRateLimitSurvivesDrainAndAdvertiserRestart() throws {
    let source = NSObject()
    let nextSource = NSObject()
    let now = Date()
    let gate = NearbyCallbackAdmission(maximumPerMinute: 8)
    gate.activate(source)
    for _ in 0..<8 {
      let token = try XCTUnwrap(gate.admit(source, now: now))
      gate.release(token)
    }
    XCTAssertNil(gate.admit(source, now: now.addingTimeInterval(59)))
    gate.activate(nextSource)
    XCTAssertNil(gate.admit(nextSource, now: now.addingTimeInterval(59)))
    XCTAssertNotNil(gate.admit(nextSource, now: now.addingTimeInterval(60)))
  }
}
