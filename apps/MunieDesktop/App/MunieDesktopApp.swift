import AppKit
import Darwin
import MunieNearby
import OSLog
import SwiftUI

@main
@MainActor
enum DesktopLaunch {
  static func main() {
    if isAppHostedTest {
      MunieDesktopApp.main()
      return
    }
    do {
      let files = FileManager.default
      let support = try files.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
      let root = support.appending(path: "Munie", directoryHint: .isDirectory)
      try files.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard let instance = try DesktopInstanceLock.acquire(in: root) else {
        activate(existingInstances.first)
        return
      }
      // A competing new build cannot finish launching without the lock. An already-running
      // older process may outlive an in-place update of its bundle, so don't inspect disk bytes.
      if let running = existingInstances.first(where: \.isFinishedLaunching) {
        activate(running)
        return
      }
      withExtendedLifetime(instance) { MunieDesktopApp.main() }
    } catch {
      Logger(subsystem: "app.munie.desktop", category: "Startup")
        .error("Unable to establish single-instance ownership.")
      Darwin.exit(EXIT_FAILURE)
    }
  }

  static var isAppHostedTest: Bool {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      return environment["XCTestConfigurationFilePath"] != nil
        || environment["XCTestBundlePath"] != nil
    #else
      return false
    #endif
  }

  private static var existingInstances: [NSRunningApplication] {
    guard let identifier = Bundle.main.bundleIdentifier else { return [] }
    return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
      $0.processIdentifier != getpid() && !$0.isTerminated
    }
  }

  private static func activate(_ app: NSRunningApplication?) {
    _ = app?.activate(options: [])
  }
}

struct MunieDesktopApp: App {
  @State private var coordinator = DesktopCoordinator()
  @NSApplicationDelegateAdaptor(DesktopApplicationDelegate.self) private var delegate

  var body: some Scene {
    Window("Munie", id: "munie") {
      DesktopHostView(coordinator: coordinator, nearby: coordinator.nearby)
        .frame(minWidth: 520, minHeight: 540)
        .task {
          delegate.coordinator = coordinator
          guard !DesktopLaunch.isAppHostedTest else { return }
          await coordinator.startOnFirstLaunch()
        }
    }
    .defaultSize(width: 580, height: 620)
    MenuBarExtra {
      DesktopMenu(coordinator: coordinator, nearby: coordinator.nearby)
    } label: {
      DesktopMenuLabel(nearby: coordinator.nearby)
    }
  }
}

@MainActor
final class DesktopApplicationDelegate: NSObject, NSApplicationDelegate {
  weak var coordinator: DesktopCoordinator?
  private var terminationPending = false

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let coordinator else { return .terminateNow }
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    Task {
      let stopped = await coordinator.stop()
      terminationPending = false
      sender.reply(toApplicationShouldTerminate: stopped)
      if !stopped {
        sender.activate(ignoringOtherApps: true)
        sender.windows.first?.makeKeyAndOrderFront(nil)
      }
    }
    return .terminateLater
  }
}
