#if os(iOS)
  import Foundation
  import Testing

  @testable import Munie

  struct RemoteNotificationTests {
    @Test func pushAndLocalNoticesRouteToTheSameTask() throws {
      let id = UUID()
      let push = try #require(RemoteNotificationRoute(userInfo: ["munieTaskID": id.uuidString]))
      let local = try #require(RemoteNotificationRoute(userInfo: ["taskID": id.uuidString]))
      #expect(push.taskID == id)
      #expect(local.taskID == id)
      #expect(RemoteNotificationRoute(userInfo: ["taskID": "new-task"]) == nil)
      #expect(RemoteNotificationRoute(userInfo: ["path": "/tmp/project"]) == nil)
    }

    @Test func conflictingOrMalformedTaskRoutesAreRejected() {
      let id = UUID()
      #expect(
        RemoteNotificationRoute(userInfo: [
          "taskID": id.uuidString, "munieTaskID": UUID().uuidString,
        ]) == nil)
      #expect(
        RemoteNotificationRoute(userInfo: [
          "taskID": 12, "munieTaskID": id.uuidString,
        ]) == nil)
    }

    @MainActor
    @Test func notificationDeduplicationHasABoundedHistory() {
      let events = RemoteNotificationEvents()
      events.record("same-event")
      events.record("same-event")
      #expect(events.contains("same-event"))
      events.record(String(repeating: "x", count: 257))
      #expect(!events.contains(String(repeating: "x", count: 257)))
      for index in 0..<1_000 { events.record("event-\(index)") }
      #expect(!events.contains("same-event"))
      #expect(events.contains("event-999"))
    }

    @MainActor
    @Test func coldShortcutKeepsNavigationIntentUntilTheAppCanPresentInput() {
      let navigation = RemoteNavigation()
      navigation.openNewTask()
      #expect(navigation.wantsNewTask)
      #expect(navigation.taskID == nil)
      let id = UUID()
      navigation.openTask(id)
      #expect(!navigation.wantsNewTask)
      #expect(navigation.taskID == id)
      let previousRoute = navigation.taskRequest
      navigation.openTask(id)
      #expect(navigation.taskRequest != previousRoute)
    }
  }
#endif
