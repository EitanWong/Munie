// Munie regression: the real onboarding never asks a phone user to run terminal commands.
import XCTest

final class MunieOnboardingUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor func testEnglishOnboardingFindsNearbyMacWithoutTerminalOrRadioFixture() {
    verify(
      language: "en", locale: "en_US", welcome: "Control Codex from your iPhone.",
      start: "Get Started", features: "What you get", find: "Find My Mac",
      title: "Connect to Your Mac", searching: "Looking for Your Mac…")
  }

  @MainActor func testChineseOnboardingFindsNearbyMacWithoutTerminalOrRadioFixture() {
    verify(
      language: "zh-Hans", locale: "zh_CN", welcome: "用 iPhone 远程控制 Codex。",
      start: "开始使用", features: "功能一览", find: "查找我的 Mac",
      title: "连接你的 Mac", searching: "正在查找你的 Mac…")
  }

  @MainActor private func verify(
    language: String, locale: String, welcome: String,
    start: String, features: String, find: String, title: String, searching: String
  ) {
    let app = XCUIApplication()
    app.launchArguments = [
      "-CodexUITestsOnboardingFixture", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
    ]
    app.launch()
    defer { app.terminate() }
    assertLabel(app.staticTexts["munie.onboarding.welcome.subtitle"], welcome)
    let button = app.buttons["munie.onboarding.continue"]
    assertLabel(button, start)
    button.tap()
    assertLabel(app.staticTexts["munie.onboarding.features.title"], features)
    assertLabel(button, find)
    button.tap()
    assertLabel(app.staticTexts["munie.nearby.title"], title)
    XCTAssertTrue(app.staticTexts[searching].waitForExistence(timeout: 10))
    for forbidden in ["npm install", "./scripts/", "/absolute/", "server address"] {
      XCTAssertFalse(
        app.staticTexts.matching(
          NSPredicate(format: "label CONTAINS[c] %@", forbidden)
        ).firstMatch.exists)
    }
    XCTAssertFalse(app.buttons["munie.onboarding.copyCommand"].exists)
    XCTAssertFalse(app.buttons["munie.onboarding.continue"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "\(language)-nearby-zero-terminal"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    // The isolated launch route disables discovery; no radio, camera, microphone or model access.
  }

  @MainActor private func assertLabel(
    _ element: XCUIElement, _ label: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let visible = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed, file: file, line: line)
    XCTAssertEqual(element.label, label, file: file, line: line)
  }
}
