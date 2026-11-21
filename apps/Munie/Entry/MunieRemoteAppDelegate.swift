#if os(iOS)
  import Observation
  import UIKit
  import UserNotifications

  @MainActor
  @Observable
  final class RemotePushRegistration {
    static let shared = RemotePushRegistration()
    var token: Data?
    var errorMessage: String?
  }

  /// The app retains this delegate through UIApplicationDelegateAdaptor.
  final class MunieRemoteAppDelegate: NSObject, UIApplicationDelegate {
    func application(
      _ application: UIApplication,
      willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      // Install before a cold-launch notification response is delivered to the application.
      UNUserNotificationCenter.current().delegate = RemoteNotificationDelegate.shared
      return true
    }

    func application(
      _ application: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
      RemotePushRegistration.shared.token = deviceToken
      RemotePushRegistration.shared.errorMessage = nil
    }

    func application(
      _ application: UIApplication,
      didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
      RemotePushRegistration.shared.errorMessage = remoteString(
        "Background alerts are unavailable. Open Munie to check task updates.")
    }
  }
#endif
