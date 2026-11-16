import XCTest

final class CaptureFlowTests: XCTestCase {
  @MainActor
  func testCapturePersistsAcrossLaunchAndCanBeDeleted() {
    let app = XCUIApplication()
    app.launchArguments = ["-munie-ui-testing", "-munie-reset-store", "-AppleLanguages", "(en)"]
    app.launch()
    let newCapture = app.buttons["newCapture"]
    XCTAssertTrue(newCapture.waitForExistence(timeout: 10))
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: newCapture)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    newCapture.tap()
    let editor = app.textViews["captureText"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText("A thought to revisit")
    app.buttons["saveCapture"].tap()
    XCTAssertTrue(app.staticTexts["A thought to revisit"].waitForExistence(timeout: 5))
    app.terminate()

    app.launchArguments = ["-munie-ui-testing", "-AppleLanguages", "(en)"]
    app.launch()
    let record = app.staticTexts["A thought to revisit"]
    XCTAssertTrue(record.waitForExistence(timeout: 10))
    record.tap()
    XCTAssertTrue(app.staticTexts["captureDetail"].waitForExistence(timeout: 5))
    app.terminate()
    app.launch()
    let restoredRecord = app.staticTexts["A thought to revisit"]
    XCTAssertTrue(restoredRecord.waitForExistence(timeout: 10))
    restoredRecord.swipeLeft()
    app.buttons["Delete"].firstMatch.tap()
    let confirmation = app.buttons["Delete"].firstMatch
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    confirmation.tap()
    XCTAssertTrue(app.staticTexts["A thought worth keeping?"].waitForExistence(timeout: 5))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["A thought worth keeping?"].waitForExistence(timeout: 10))
  }
}
