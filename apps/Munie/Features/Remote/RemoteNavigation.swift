#if os(iOS)
  import Foundation
  import Observation

  /// Routes carry only IDs and navigation intent, never prompts, credentials or approvals.
  @MainActor
  @Observable
  final class RemoteNavigation {
    static let shared = RemoteNavigation()
    var taskID: UUID?
    var taskRequest = UUID()
    var newTaskRequest = UUID()
    var wantsNewTask = false

    func openNewTask() {
      taskID = nil
      wantsNewTask = true
      newTaskRequest = UUID()
    }

    func openTask(_ id: UUID) {
      wantsNewTask = false
      taskID = id
      taskRequest = UUID()
    }
  }
#endif
