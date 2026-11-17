import XCTest

final class RemoteFlowTests: XCTestCase {
  @MainActor
  func testNativeRemoteEntryHasPairingOrKnownConnection() {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)"]
    app.launch()
    let invitation = app.textViews["remote.pair.invitation"]
    let newTask = app.buttons["remote.newTask"]
    XCTAssertTrue(invitation.waitForExistence(timeout: 15) || newTask.waitForExistence(timeout: 10))
    if invitation.exists {
      XCTAssertTrue(app.buttons["remote.pair.request"].exists)
      XCTAssertFalse(app.buttons["remote.pair.request"].isEnabled)
    }
  }

  /// Owner-authorized physical-device acceptance only. Default CI does not consume model credits.
  @MainActor
  func testPairedRealTaskAndRestartRecovery() throws {
    guard let invitation = ProcessInfo.processInfo.environment["MUNIE_ACCEPTANCE_INVITATION"] else {
      throw XCTSkip(
        "Requires private invitation and explicit disposable-project real-model authorization")
    }
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)"]
    app.launch()
    let editor = app.textViews["remote.pair.invitation"]
    XCTAssertTrue(editor.waitForExistence(timeout: 15))
    editor.tap()
    editor.typeText(invitation)
    app.buttons["remote.pair.request"].tap()
    let pairingID = app.staticTexts["remote.pair.id"]
    let pairingFingerprint = app.staticTexts["remote.pair.fingerprint"]
    XCTAssertTrue(pairingID.waitForExistence(timeout: 15))
    XCTAssertTrue(pairingFingerprint.waitForExistence(timeout: 15))
    let rawID = try XCTUnwrap(pairingID.value as? String)
    let fingerprint = try XCTUnwrap(pairingFingerprint.value as? String)
    guard rawID.utf8.count == 36, UUID(uuidString: rawID) != nil,
      fingerprint.utf8.count == 16,
      fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
      XCTFail("The disposable pairing identity has an invalid shape.")
      return
    }
    FileHandle.standardOutput.write(Data("MUNIE_DEVICE_PAIR \(rawID) \(fingerprint)\n".utf8))
    let newTask = app.buttons["remote.newTask"]
    // The Mac operator must explicitly verify and confirm this candidate while the test waits.
    XCTAssertTrue(newTask.waitForExistence(timeout: 100))
    newTask.tap()
    let composer = app.textViews["remote.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["remote.voice"].exists)
    composer.tap()
    composer.typeText("Reply exactly MUNIE_PHONE_REAL_OK. Do not use tools.")
    app.buttons["remote.submit"].tap()
    let result = app.staticTexts["MUNIE_PHONE_REAL_OK"]
    XCTAssertTrue(result.waitForExistence(timeout: 150))
    app.terminate()
    app.launch()
    let original = app.staticTexts["Reply exactly MUNIE_PHONE_REAL_OK. Do not use tools."]
      .firstMatch
    XCTAssertTrue(original.waitForExistence(timeout: 20))
    original.tap()
    XCTAssertTrue(result.waitForExistence(timeout: 20))
  }
}
