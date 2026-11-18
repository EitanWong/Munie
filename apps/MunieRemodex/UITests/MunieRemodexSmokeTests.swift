// Munie-specific smoke tests for the adopted Remodex client. No network/model or microphone.
import XCTest

final class MunieRemodexSmokeTests: XCTestCase {
  @MainActor
  func testAdoptedConversationTimelineRendersWithoutNetwork() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-CodexUITestsFixture", "-CodexUITestsMessageCount", "24", "-AppleLanguages", "(en)",
    ]
    app.launch()
    let timeline = app.scrollViews["turn.timeline.scrollview"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 20))
    timeline.swipeUp()
    timeline.swipeDown()
    XCTAssertTrue(timeline.exists)
    app.terminate()
  }

  @MainActor
  func testAdoptedTimelineUsesSimplifiedChineseCatalogWithoutNetwork() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-CodexUITestsFixture", "-CodexUITestsMessageCount", "24", "-AppleLanguages", "(zh-Hans)",
      "-AppleLocale", "zh_CN",
    ]
    app.launch()
    XCTAssertTrue(app.navigationBars["界面测试"].waitForExistence(timeout: 20))
    let timeline = app.scrollViews["turn.timeline.scrollview"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 20))
    timeline.swipeUp()
    timeline.swipeDown()
    XCTAssertTrue(timeline.exists)
    app.terminate()
  }

}
