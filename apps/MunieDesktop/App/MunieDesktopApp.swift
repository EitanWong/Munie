import AppKit
import MunieNearby
import SwiftUI

@main
struct MunieDesktopApp: App {
  @State private var coordinator = DesktopCoordinator()
  @NSApplicationDelegateAdaptor(DesktopApplicationDelegate.self) private var delegate

  var body: some Scene {
    Window("Munie", id: "munie") {
      DesktopHostView(coordinator: coordinator, nearby: coordinator.nearby)
        .frame(minWidth: 520, minHeight: 540)
        .task {
          delegate.coordinator = coordinator
          #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["XCTestConfigurationFilePath"] != nil
              || environment["XCTestBundlePath"] != nil
            {
              return
            }
          #endif
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
