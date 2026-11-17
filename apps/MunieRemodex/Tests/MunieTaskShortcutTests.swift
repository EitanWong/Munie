import AppIntents
import XCTest

@testable import MunieRemodex

@MainActor
final class MunieTaskShortcutTests: XCTestCase {
  override func tearDown() {
    _ = RemodexQuickActionCenter.consumePendingAction()
    super.tearDown()
  }

  func testShortcutQueuesNewDraftBeforeTheRootSubscribes() async throws {
    _ = RemodexQuickActionCenter.consumePendingAction()
    _ = try await NewMunieTaskIntent().perform()
    XCTAssertEqual(RemodexQuickActionCenter.consumePendingAction(), .newChat)
    XCTAssertNil(RemodexQuickActionCenter.consumePendingAction())
  }

  func testShortcutNotifiesAnAlreadyMountedRootOnce() async throws {
    var actions: [RemodexQuickAction] = []
    let token = NotificationCenter.default.addObserver(
      forName: RemodexQuickActionCenter.didReceiveQuickAction, object: nil, queue: .main
    ) { notification in
      MainActor.assumeIsolated {
        if let action = notification.userInfo?["action"] as? RemodexQuickAction {
          actions.append(action)
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    _ = try await NewMunieTaskIntent().perform()
    XCTAssertEqual(actions, [.newChat])
  }
}
