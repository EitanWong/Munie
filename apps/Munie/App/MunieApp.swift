import MunieCore
import SwiftUI

@main
struct MunieApp: App {
  private let startup: Result<CaptureModel, Error>

  init() {
    startup = Result {
      let manager = FileManager.default
      #if os(tvOS)
        // tvOS only permits purgeable local storage; this is not a durable backup.
        let storageDirectory = FileManager.SearchPathDirectory.cachesDirectory
      #else
        let storageDirectory = FileManager.SearchPathDirectory.applicationSupportDirectory
      #endif
      let support = try manager.url(
        for: storageDirectory, in: .userDomainMask,
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
    #if os(macOS)
      // One window prevents multiple editors from sharing the same in-memory draft.
      Window("Munie", id: "main") { captureContent }
    #else
      WindowGroup { captureContent }
    #endif
  }

  @ViewBuilder
  private var captureContent: some View {
    switch startup {
    case .success(let model):
      #if os(watchOS)
        WatchCaptureView(model: model)
      #else
        CaptureView(model: model)
      #endif
    case .failure:
      ContentUnavailableView(
        "Storage unavailable", systemImage: "externaldrive.badge.exclamationmark",
        description: Text("Munie could not open local storage. Reopen the app to try again."))
    }
  }
}
