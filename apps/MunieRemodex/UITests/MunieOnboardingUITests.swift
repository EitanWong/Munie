// Munie regression: exercise the real first-run pages through the isolated DEBUG entry route.
import XCTest

final class MunieOnboardingUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testEnglishOnboardingFivePagesWithoutNetworkOrCamera() {
    verifyFivePages(language: "en", locale: "en_US", copy: .english)
  }

  @MainActor
  func testSimplifiedChineseOnboardingFivePagesWithoutNetworkOrCamera() {
    verifyFivePages(language: "zh-Hans", locale: "zh_CN", copy: .simplifiedChinese)
  }

  @MainActor
  private func verifyFivePages(language: String, locale: String, copy: ExpectedCopy) {
    let app = XCUIApplication()
    app.launchArguments = [
      "-CodexUITestsOnboardingFixture", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
    ]
    app.launch()
    defer { app.terminate() }

    assertText(app.staticTexts["munie.onboarding.welcome.subtitle"], equals: copy.welcome)
    assertPage(1, app: app, language: language)
    let sourceBadge = app.descendants(matching: .any)["munie.onboarding.openSource"].firstMatch
    assertText(sourceBadge, equals: copy.openSource)
    attachScreenshot(app, name: "\(language)-01-welcome")
    tapContinue(app, title: copy.getStarted)

    assertText(app.staticTexts["munie.onboarding.features.title"], equals: copy.featuresTitle)
    assertText(app.staticTexts[copy.featuresDetail], equals: copy.featuresDetail)
    for text in copy.featureLabels {
      assertText(app.staticTexts[text], equals: text)
    }
    assertPage(2, app: app, language: language)
    attachScreenshot(app, name: "\(language)-02-features")
    tapContinue(app, title: copy.setUp)

    assertStep(1, app: app, copy: copy)
    assertPage(3, app: app, language: language)
    attachScreenshot(app, name: "\(language)-03-install")
    tapContinue(app, title: copy.continueTitle)
    let reminder = app.alerts[copy.reminderTitle]
    XCTAssertTrue(reminder.waitForExistence(timeout: 8))
    let hierarchy = XCTAttachment(string: reminder.debugDescription)
    hierarchy.name = "\(language)-install-alert-accessibility"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    attachScreenshot(app, name: "\(language)-install-reminder")
    // XCTest identifier subscripts reject strings over 128 characters and may prefer an
    // explicit accessibility identifier over an alert action's label. Match full labels directly.
    let message = reminder.staticTexts.matching(
      NSPredicate(format: "label == %@", copy.reminderMessage)
    ).firstMatch
    let stay = reminder.buttons.matching(NSPredicate(format: "label == %@", copy.stay)).firstMatch
    let understood = reminder.buttons.matching(
      NSPredicate(format: "label == %@", copy.understood)
    ).firstMatch
    assertText(message, equals: copy.reminderMessage)
    assertText(stay, equals: copy.stay)
    assertText(understood, equals: copy.understood)
    stay.tap()
    assertStep(1, app: app, copy: copy)
    assertPage(3, app: app, language: language)
    tapContinue(app, title: copy.continueTitle)
    XCTAssertTrue(reminder.waitForExistence(timeout: 8))
    understood.tap()

    assertStep(2, app: app, copy: copy)
    assertText(app.staticTexts[copy.bridgeCaption], equals: copy.bridgeCaption)
    assertPage(4, app: app, language: language)
    attachScreenshot(app, name: "\(language)-04-prepare-mac")
    tapContinue(app, title: copy.continueTitle)

    assertStep(3, app: app, copy: copy)
    assertPage(5, app: app, language: language)
    assertText(app.buttons["munie.onboarding.scan"], equals: copy.scan)
    assertText(app.buttons["munie.onboarding.pairWithCode"], equals: copy.pairWithCode)
    XCTAssertFalse(app.buttons["munie.onboarding.continue"].exists)
    attachScreenshot(app, name: "\(language)-05-pairing")
    // Stop at the real entry buttons. Do not request camera access, pair, follow links or copy to pasteboard.
  }

  @MainActor
  private func assertStep(_ number: Int, app: XCUIApplication, copy: ExpectedCopy) {
    assertText(
      app.staticTexts["munie.onboarding.step.title.\(number)"], equals: copy.stepTitles[number - 1])
    assertText(
      app.staticTexts[copy.stepDescriptions[number - 1]], equals: copy.stepDescriptions[number - 1])
    let command = [
      "npm install -g @openai/codex@0.162.1",
      "./scripts/setup-remodex.sh",
      "./scripts/run-remodex-local.sh --codex /absolute/codex --project /absolute/authorized/project",
    ][number - 1]
    let card = app.descendants(matching: .any)["munie.onboarding.command.\(number)"].firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 8))
    assertText(card.staticTexts[command], equals: command)
    assertText(card.buttons["munie.onboarding.copyCommand"], equals: copy.copyCommand)
  }

  @MainActor
  private func assertPage(_ page: Int, app: XCUIApplication, language: String) {
    let expected = language == "en" ? "Page \(page) of 5" : "第 \(page) 页，共 5 页"
    assertText(
      app.descendants(matching: .any)["munie.onboarding.pageIndicator"].firstMatch, equals: expected
    )
  }

  @MainActor
  private func tapContinue(_ app: XCUIApplication, title: String) {
    let button = app.buttons["munie.onboarding.continue"]
    assertText(button, equals: title)
    button.tap()
  }

  @MainActor
  private func assertText(
    _ element: XCUIElement, equals expected: String, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    // Page TabViews may preload adjacent pages; existence alone does not establish the current visible page.
    let visible = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed, file: file, line: line)
    XCTAssertEqual(element.label, expected, file: file, line: line)
  }

  @MainActor
  private func attachScreenshot(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private struct ExpectedCopy {
    let welcome: String
    let featuresTitle: String
    let featuresDetail: String
    let featureLabels: [String]
    let stepTitles: [String]
    let stepDescriptions: [String]
    let bridgeCaption: String
    let getStarted: String
    let setUp: String
    let continueTitle: String
    let reminderTitle: String
    let reminderMessage: String
    let stay: String
    let understood: String
    let scan: String
    let pairWithCode: String
    let copyCommand: String
    let openSource: String

    static let english = Self(
      welcome: "Control Codex from your iPhone.",
      featuresTitle: "What you get",
      featuresDetail: "Codex runs on your Mac.\nYour iPhone is the remote.",
      featureLabels: [
        "Fast mode", "Lower-latency turns for quick interactions", "Git from your phone",
        "Commit, push, pull, and switch branches", "End-to-end encrypted",
        "The relay never sees your prompts or code", "Voice mode",
        "Talk to Codex with speech-to-text",
        "Subagents, skills and /commands", "Spawn and monitor parallel agents from your phone",
      ],
      stepTitles: ["Install Codex CLI", "Prepare Munie on your Mac", "Start Pairing"],
      stepDescriptions: [
        "Codex runs in Terminal on your Mac. Munie lets you control it from your iPhone.",
        "From your Munie repository on the Mac, prepare the pinned local bridge.",
        "On your Mac, choose the Codex executable and authorized project. Scan the pairing QR code shown by the local bridge.",
      ],
      bridgeCaption:
        "Run from the Munie repository. The relay endpoint is configured locally and is not an upstream hosted service.",
      getStarted: "Get Started", setUp: "Set Up", continueTitle: "Continue",
      reminderTitle: "Install Codex CLI First",
      reminderMessage:
        "Before continuing, run \"npm install -g @openai/codex@0.162.1\" in Terminal on your Mac. Munie needs Codex CLI installed and available in your Mac's PATH.",
      stay: "Stay Here", understood: "Understood", scan: "Scan with QR Code",
      pairWithCode: "Pair with Code",
      copyCommand: "Copy Command", openSource: "Open source on GitHub")

    static let simplifiedChinese = Self(
      welcome: "用 iPhone 远程控制 Codex。",
      featuresTitle: "功能一览",
      featuresDetail: "Codex 在 Mac 上执行。\niPhone 用于远程控制。",
      featureLabels: [
        "快速模式", "以更低延迟快速交互", "在手机上使用 Git", "提交、推送、拉取和切换分支", "端到端加密",
        "中继无法读取你的提示词或代码", "语音模式", "将语音转成文字，与 Codex 对话", "子 Agent、技能与 /commands",
        "在手机上启动并监控并行 Agent",
      ],
      stepTitles: ["安装 Codex CLI", "在 Mac 上准备 Munie", "开始配对"],
      stepDescriptions: [
        "Codex 在 Mac 的终端中运行。Munie 让你通过 iPhone 远程控制它。",
        "在 Mac 的 Munie 仓库目录中准备已固定版本的本地桥接。",
        "在 Mac 上选择 Codex 可执行文件与已授权项目，再扫描本地桥接显示的配对二维码。",
      ],
      bridgeCaption: "在 Munie 仓库目录中运行。中继地址在本地配置，不使用上游托管服务。",
      getStarted: "开始使用", setUp: "开始设置", continueTitle: "继续",
      reminderTitle: "请先安装 Codex CLI",
      reminderMessage:
        "继续前，请在 Mac 的终端中运行“npm install -g @openai/codex@0.162.1”。Munie 需要先在 Mac 上安装 Codex CLI，并将其加入 PATH。",
      stay: "留在此页", understood: "知道了", scan: "扫描二维码", pairWithCode: "使用配对码",
      copyCommand: "复制命令", openSource: "在 GitHub 上查看开源项目")
  }
}
