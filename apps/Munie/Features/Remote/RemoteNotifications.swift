#if os(iOS)
  import Foundation
  import MunieRemote
  import Observation
  import UserNotifications

  @MainActor
  @Observable
  final class RemoteNotifications {
    private(set) var permissionGranted = false
    private(set) var errorMessage: String?
    private let delegate = RemoteNotificationDelegate.shared
    private var observed: [UUID: String] = [:]
    private var hasBaseline = false
    private var observedHostID: UUID?
    private var observationGeneration = UUID()

    func install() async {
      let center = UNUserNotificationCenter.current()
      center.delegate = delegate
      let settings = await center.notificationSettings()
      permissionGranted = [.authorized, .provisional, .ephemeral].contains(
        settings.authorizationStatus)
    }

    func requestPermission() async {
      errorMessage = nil
      do {
        permissionGranted = try await UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .sound, .badge])
        if !permissionGranted {
          errorMessage = remoteString(
            "Notifications are off. You can still check every task in Munie.")
        }
      } catch {
        errorMessage = remoteString(
          "Notifications could not be enabled. Check Settings or try again.")
      }
    }

    /// Notices describe newly observed authoritative transitions. Polling is foreground-only.
    func observe(_ status: RemoteStatus) async {
      let generation = UUID()
      observationGeneration = generation
      if observedHostID != status.hostID {
        hasBaseline = false
        observed = [:]
      }
      let previous = observed
      let hadBaseline = hasBaseline
      let current = Dictionary(uniqueKeysWithValues: status.tasks.map { ($0.id, stateKey($0)) })
      observed = current
      hasBaseline = true
      observedHostID = status.hostID
      guard hadBaseline, permissionGranted, previous != current else { return }
      let center = UNUserNotificationCenter.current()
      let delivered = await center.deliveredNotifications()
      guard observationGeneration == generation else { return }
      for notification in delivered {
        if let event = notification.request.content.userInfo["munieEventID"] as? String {
          RemoteNotificationEvents.shared.record(event)
        }
      }
      for task in status.tasks where previous[task.id] != current[task.id] {
        guard observationGeneration == generation else { return }
        guard task.approval != nil || task.phase == .completed || task.phase == .failed else {
          continue
        }
        guard !RemoteNotificationEvents.shared.contains(stateKey(task)) else { continue }
        let content = UNMutableNotificationContent()
        content.title = "Munie"
        if task.approval != nil {
          content.body = remoteString(
            "A task needs your approval. Open Munie to inspect the action.")
        } else if task.phase == .failed {
          content.body = remoteString("A task failed. Open Munie to inspect the result.")
        } else {
          content.body = remoteString("A task completed. Open Munie to inspect the result.")
        }
        content.sound = .default
        content.userInfo = ["taskID": task.id.uuidString, "munieEventID": stateKey(task)]
        content.threadIdentifier = task.id.uuidString
        let identifier = "munie.\(task.id).\(stateKey(task))"
        do {
          try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        } catch {
          errorMessage = remoteString(
            "A task notice could not be scheduled. The task remains available in Munie.")
        }
      }
    }

    private func stateKey(_ task: RemoteTask) -> String {
      let event = task.approval.map { "approval:\($0.id)" } ?? task.phase.rawValue
      return "\(task.requestID):\(event)"
    }
  }

  @MainActor
  final class RemoteNotificationEvents {
    static let shared = RemoteNotificationEvents()
    private var events: [String] = []

    func contains(_ event: String) -> Bool { events.contains(event) }
    func record(_ event: String) {
      guard event.utf8.count <= 256, !events.contains(event) else { return }
      events.append(event)
      if events.count > 1_000 { events.removeFirst(events.count - 1_000) }
    }
  }

  @MainActor
  final class RemoteNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RemoteNotificationDelegate()

    nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
      guard
        let route = RemoteNotificationRoute(
          userInfo: response.notification.request.content.userInfo)
      else { return }
      await MainActor.run {
        if let event = route.eventID { RemoteNotificationEvents.shared.record(event) }
        RemoteNavigation.shared.openTask(route.taskID)
      }
    }

    nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
      let event = notification.request.content.userInfo["munieEventID"] as? String
      let shouldPresent = await MainActor.run {
        if let event {
          if RemoteNotificationEvents.shared.contains(event) { return false }
          RemoteNotificationEvents.shared.record(event)
        }
        return true
      }
      return shouldPresent ? [.banner, .sound] : []
    }
  }
#endif
