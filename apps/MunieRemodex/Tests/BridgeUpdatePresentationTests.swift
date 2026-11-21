import Foundation
import XCTest

@testable import MunieRemodex

final class BridgeUpdatePresentationTests: XCTestCase {
  // Swift 6.2 compatibility: avoid inferred isolated teardown (Swift #85663).
  nonisolated deinit {}

  func testCommandPresenceSelectsMacAppUpdateWithoutDisplayingDeveloperInstructions() {
    for command in [
      "./scripts/setup-remodex.sh", "npm install -g upstream", "", "TOKEN=secret; run-tool",
    ] {
      let presentation = BridgeUpdatePresentation(command: command)
      XCTAssertEqual(presentation.target, .macApp)
      for text in [presentation.title, presentation.message, presentation.guidance] {
        XCTAssertFalse(text.contains("./scripts/"))
        XCTAssertFalse(text.contains("npm"))
        XCTAssertFalse(text.contains("TOKEN"))
        XCTAssertFalse(text.contains("upstream"))
      }
    }
  }

  func testAbsentCommandSelectsIPhoneAppUpdateAndKeepsCompatibilityRequirement() {
    let phone = BridgeUpdatePresentation(command: nil)
    let mac = BridgeUpdatePresentation(command: "developer-only")
    XCTAssertEqual(phone.target, .iPhoneApp)
    XCTAssertNotEqual(phone.title, mac.title)
    XCTAssertNotEqual(phone.guidance, mac.guidance)
    XCTAssertEqual(phone.message, mac.message)
    XCTAssertFalse(phone.message.isEmpty)
  }
}
