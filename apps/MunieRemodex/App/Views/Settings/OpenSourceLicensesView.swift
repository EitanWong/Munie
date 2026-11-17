// Munie modification: readable bundled acknowledgements for adopted open-source dependencies.
import SwiftUI

struct OpenSourceLicensesView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var content: String?
  @State private var loadFailed = false

  var body: some View {
    NavigationStack {
      ScrollView {
        if let content {
          Text(content).font(.footnote.monospaced()).textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading
          ).padding()
        } else if loadFailed {
          Text("Licenses could not be loaded.").padding()
        } else {
          ProgressView()
        }
      }
      .navigationTitle("Open-source licenses")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .task {
        guard content == nil else { return }
        guard let url = Bundle.main.url(forResource: "OpenSourceNotices", withExtension: "txt")
        else {
          loadFailed = true
          return
        }
        do {
          content = try await Task.detached { try String(contentsOf: url, encoding: .utf8) }.value
        } catch { loadFailed = true }
      }
    }
  }
}
