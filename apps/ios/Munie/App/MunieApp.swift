import MunieCore
import SwiftUI

@main
struct MunieApp: App {
  private let startup: Result<CaptureModel, Error>

  init() {
    startup = Result {
      let manager = FileManager.default
      let support = try manager.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
      var directory = support.appending(path: "Munie", directoryHint: .isDirectory)
      #if DEBUG
        // UI automation uses its own data directory; personal records are never reset.
        if ProcessInfo.processInfo.arguments.contains("-munie-ui-testing") {
          directory = support.appending(path: "MunieUITests", directoryHint: .isDirectory)
          if ProcessInfo.processInfo.arguments.contains("-munie-reset-store"),
            manager.fileExists(atPath: directory.path)
          {
            try manager.removeItem(at: directory)
          }
        }
      #endif
      return CaptureModel(
        store: FileCaptureStore(fileURL: directory.appending(path: "captures.json")))
    }
  }

  var body: some Scene {
    WindowGroup {
      switch startup {
      case .success(let model):
        CaptureView(model: model)
      case .failure:
        ContentUnavailableView(
          "Storage unavailable", systemImage: "externaldrive.badge.exclamationmark",
          description: Text("Munie could not open local storage. Reopen the app to try again."))
      }
    }
  }
}
