#if os(iOS)
  import Foundation

  /// Push and local notices share one fixed navigation schema. No action is executed from a notice.
  struct RemoteNotificationRoute: Sendable {
    let taskID: UUID
    let eventID: String?

    init?(userInfo: [AnyHashable: Any]) {
      let local = userInfo["taskID"] as? String
      let remote = userInfo["munieTaskID"] as? String
      guard userInfo["taskID"] == nil || local != nil,
        userInfo["munieTaskID"] == nil || remote != nil,
        let raw = local ?? remote, let id = UUID(uuidString: raw)
      else { return nil }
      if let local, let remote, local != remote { return nil }
      taskID = id
      if let event = userInfo["munieEventID"] as? String, event.utf8.count <= 256 {
        eventID = event
      } else {
        eventID = nil
      }
    }
  }
#endif
