import MunieCore
import SwiftUI

struct CaptureView: View {
  @Bindable var model: CaptureModel
  @State private var isComposing = false
  @State private var selectedID: CaptureRecord.ID?
  @State private var pendingDeletion: CaptureRecord?

  var body: some View {
    NavigationSplitView {
      List(selection: $selectedID) {
        ForEach(model.filteredRecords) { record in
          NavigationLink(value: record.id) {
            VStack(alignment: .leading, spacing: 6) {
              Text(record.text).lineLimit(3)
              Text(record.createdAt, style: .date)
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .tag(record.id)
          .swipeActions {
            Button("Delete", role: .destructive) { pendingDeletion = record }
          }
        }
      }
      .overlay {
        if !model.hasLoaded {
          if model.isBusy {
            ProgressView()
          } else {
            ContentUnavailableView {
              Label("Could not load captures", systemImage: "externaldrive.badge.exclamationmark")
            } actions: {
              Button("Retry") { Task { await model.load() } }
            }
          }
        } else if model.records.isEmpty {
          ContentUnavailableView(
            "A thought worth keeping?", systemImage: "sparkle",
            description: Text("Capture it now. Find it here later."))
        } else if model.filteredRecords.isEmpty {
          ContentUnavailableView.search(text: model.search)
        }
      }
      .navigationTitle("Munie")
      .searchable(text: $model.search, prompt: "Search captures")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("New capture", systemImage: "square.and.pencil") { isComposing = true }
            .accessibilityIdentifier("newCapture")
            .disabled(!model.hasLoaded || model.isBusy)
        }
      }
      .refreshable { await model.load() }
    } detail: {
      if let record = model.records.first(where: { $0.id == selectedID }) {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text(record.createdAt, format: .dateTime)
              .font(.caption).foregroundStyle(.secondary)
            Text(record.text).textSelection(.enabled)
              .accessibilityIdentifier("captureDetail")
          }
          .frame(maxWidth: 680, alignment: .leading)
          .padding()
          .frame(maxWidth: .infinity)
        }
        .navigationTitle("Capture")
        .toolbar {
          Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = record }
            .disabled(model.isBusy)
        }
      } else {
        ContentUnavailableView(
          "Your personal space", systemImage: "tray",
          description: Text("Select a capture or start a new one. Saved on this device."))
      }
    }
    .task { await model.load() }
    .sheet(isPresented: $isComposing) { CaptureComposer(model: model) }
    .alert("Unable to complete", isPresented: errorPresented) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .confirmationDialog(
      "Delete this capture?", isPresented: deletionPresented, titleVisibility: .visible,
      presenting: pendingDeletion
    ) { record in
      Button("Delete", role: .destructive) {
        pendingDeletion = nil
        Task {
          await model.delete(record)
          if !model.records.contains(where: { $0.id == selectedID }) { selectedID = nil }
        }
      }
    } message: { _ in
      Text("This cannot be undone.")
    }
  }

  private var errorPresented: Binding<Bool> {
    Binding(
      get: { !isComposing && model.errorMessage != nil },
      set: { if !$0 { model.errorMessage = nil } })
  }

  private var deletionPresented: Binding<Bool> {
    Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
  }
}

private struct CaptureComposer: View {
  @Bindable var model: CaptureModel
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isFocused: Bool

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        Text("What is on your mind?").font(.headline)
        TextEditor(text: $model.draft)
          .disabled(model.isBusy)
          .focused($isFocused)
          .accessibilityLabel("Capture text")
          .accessibilityIdentifier("captureText")
        Text("Saved locally on this device.")
          .font(.caption).foregroundStyle(.secondary)
        if model.draft.count > FileCaptureStore.maximumTextLength {
          Text("Keep each capture within 10,000 characters.")
            .font(.caption).foregroundStyle(.red)
        }
      }
      .padding()
      .navigationTitle("New capture")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }.disabled(model.isBusy)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task { if await model.save() { dismiss() } }
          }
          .accessibilityIdentifier("saveCapture")
          .disabled(!model.canSave)
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
      .task { isFocused = true }
    }
  }
}
