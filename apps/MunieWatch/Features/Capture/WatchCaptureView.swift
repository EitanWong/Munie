import MunieCore
import SwiftUI

struct WatchCaptureView: View {
  @Bindable var model: CaptureModel
  @State private var isComposing = false
  @State private var pendingDeletion: CaptureRecord?

  var body: some View {
    NavigationStack {
      List {
        Button("New capture", systemImage: "square.and.pencil") { isComposing = true }
          .disabled(!model.hasLoaded || model.isBusy)
        if !model.hasLoaded {
          if model.isBusy {
            ProgressView()
          } else {
            Button("Retry") { Task { await model.load() } }
          }
        } else if model.records.isEmpty {
          Text("A thought worth keeping?")
        }
        ForEach(model.records) { record in
          NavigationLink {
            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
                Text(record.createdAt, style: .date).font(.caption)
                Text(record.text)
                Button("Delete", role: .destructive) { pendingDeletion = record }
                  .disabled(model.isBusy)
              }
            }
            .navigationTitle("Capture")
          } label: {
            Text(record.text).lineLimit(3)
          }
        }
      }
      .navigationTitle("Munie")
      .task { await model.load() }
      .sheet(isPresented: $isComposing) { WatchCaptureComposer(model: model) }
      .alert(
        "Unable to complete",
        isPresented: Binding(
          get: { !isComposing && model.errorMessage != nil },
          set: { if !$0 { model.errorMessage = nil } })
      ) {
        Button("OK") { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "")
      }
      .confirmationDialog(
        "Delete this capture?",
        isPresented: Binding(
          get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
        titleVisibility: .visible, presenting: pendingDeletion
      ) { record in
        Button("Delete", role: .destructive) {
          pendingDeletion = nil
          Task { await model.delete(record) }
        }
      } message: { _ in
        Text("This cannot be undone.")
      }
    }
  }
}

private struct WatchCaptureComposer: View {
  @Bindable var model: CaptureModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        TextField("Capture text", text: $model.draft)
          .disabled(model.isBusy)
        Text("Saved locally on this device.").font(.caption)
        if model.draft.count > FileCaptureStore.maximumTextLength {
          Text("Keep each capture within 10,000 characters.").font(.caption)
        }
        Button("Save") {
          Task { if await model.save() { dismiss() } }
        }
        .disabled(!model.canSave)
      }
      .navigationTitle("New capture")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }.disabled(model.isBusy)
        }
      }
      .interactiveDismissDisabled(model.isBusy)
      .alert(
        "Unable to complete",
        isPresented: Binding(
          get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
      ) {
        Button("OK") { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "")
      }
    }
  }
}
