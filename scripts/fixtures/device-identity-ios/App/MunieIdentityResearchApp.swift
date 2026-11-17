import Foundation
import SwiftUI

@main
struct MunieIdentityResearchApp: App {
  init() {
    do {
      let input = try ResearchInput.parse(ProcessInfo.processInfo.arguments)
      let files = try ResearchFiles()
      files.recordProgress(.appInitialized, input: input)
    } catch {
      print("identity-research-progress-unavailable")
    }
  }

  var body: some Scene {
    WindowGroup {
      ResearchView()
    }
  }
}

private struct ResearchView: View {
  @State private var started = false
  @State private var finished = false

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "key.fill")
        .font(.largeTitle)
        .accessibilityHidden(true)
      Text("Identity research / 身份研究")
        .font(.headline)
      Text(finished ? "Finished / 已结束" : "Running / 正在运行")
    }
    .padding()
    .task {
      guard !started else { return }
      started = true
      let arguments = ProcessInfo.processInfo.arguments
      // All Security and file operations run serially inside this detached task.
      await Task.detached(priority: .utility) {
        IdentityResearch.run(arguments: arguments)
      }.value
      finished = true
    }
  }
}
