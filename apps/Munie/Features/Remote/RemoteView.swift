#if os(iOS)
  import MunieRemote
  import SwiftUI

  struct RemoteView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = RemoteCoordinator()
    @State private var navigation = RemoteNavigation.shared
    @State private var pushRegistration = RemotePushRegistration.shared
    @State private var path: [UUID] = []
    @State private var showNewTask = false
    @State private var showSettings = false

    var body: some View {
      NavigationStack(path: $path) {
        Group {
          if coordinator.hasConnection {
            taskList
          } else {
            RemotePairingView(coordinator: coordinator)
          }
        }
        .navigationTitle("Munie")
        .toolbar {
          if coordinator.hasConnection {
            ToolbarItem(placement: .primaryAction) {
              Button(remoteString("New task"), systemImage: "square.and.pencil") {
                showNewTask = true
              }
              .disabled(coordinator.model.status?.projects.isEmpty != false)
              .accessibilityIdentifier("remote.newTask")
            }
          }
          ToolbarItem(placement: .topBarLeading) {
            Button(remoteString("Connection settings"), systemImage: "gearshape") {
              showSettings = true
            }
          }
        }
        .navigationDestination(for: UUID.self) { id in
          RemoteConversationView(coordinator: coordinator, taskID: id)
        }
      }
      .sheet(isPresented: $showNewTask) {
        RemoteNewTaskView(coordinator: coordinator) { taskID in path = [taskID] }
      }
      .sheet(isPresented: $showSettings) { RemoteConnectionSettings(coordinator: coordinator) }
      .task {
        await coordinator.start()
        if let id = navigation.taskID {
          path = [id]
        } else if coordinator.hasConnection, navigation.wantsNewTask {
          showNewTask = true
          navigation.wantsNewTask = false
        }
      }
      .task(id: pushRegistration.token) {
        if let token = pushRegistration.token, coordinator.hasConnection {
          await coordinator.registerNotificationToken(token)
        }
      }
      .task(id: coordinator.hasConnection) {
        if coordinator.hasConnection, navigation.wantsNewTask {
          showNewTask = true
          navigation.wantsNewTask = false
        }
        if coordinator.hasConnection, let token = pushRegistration.token {
          await coordinator.registerNotificationToken(token)
        }
      }
      .task(id: scenePhase) {
        if scenePhase == .active {
          await coordinator.start()
          await coordinator.notifications.install()
          if coordinator.hasConnection { await coordinator.refresh() }
        } else {
          coordinator.cancelPairing()
        }
      }
      .task(id: coordinator.shouldPoll && scenePhase == .active) {
        if scenePhase == .active { await coordinator.pollWhileActive() }
      }
      .task(id: coordinator.hasConnection ? path.last : nil) {
        if coordinator.hasConnection { await coordinator.model.selectTask(path.last) }
      }
      .onChange(of: navigation.taskRequest) { _, _ in
        if let id = navigation.taskID {
          showNewTask = false
          path = [id]
        }
      }
      .onChange(of: navigation.newTaskRequest) { _, _ in
        path = []
        if coordinator.hasConnection {
          showNewTask = true
          navigation.wantsNewTask = false
        }
      }
      .onOpenURL { url in
        // Only a fixed navigation route is accepted. Input and credentials never come from URLs.
        guard url.scheme == "munie", url.host == "task", url.query == nil, url.fragment == nil,
          let id = UUID(uuidString: String(url.path.dropFirst()))
        else { return }
        navigation.openTask(id)
      }
      .alert(
        remoteString("Connection needs attention"),
        isPresented: Binding(
          get: { coordinator.errorMessage != nil },
          set: { if !$0 { coordinator.errorMessage = nil } }
        )
      ) {
        Button(remoteString("OK"), role: .cancel) { coordinator.errorMessage = nil }
      } message: {
        Text(coordinator.errorMessage ?? "")
      }
    }

    private var taskList: some View {
      List {
        Section {
          RemoteConnectionSummary(coordinator: coordinator)
          if let failure = coordinator.model.lastError { RemoteErrorView(error: failure) }
          if coordinator.model.pendingSubmission != nil || coordinator.model.hasUnresolvedRecovery {
            RemotePendingSubmissionView(coordinator: coordinator)
          }
        }
        if let status = coordinator.model.status {
          ForEach(status.projects) { project in
            Section(project.name) {
              let tasks = status.tasks.filter { $0.projectID == project.id }
              if tasks.isEmpty {
                Text(remoteString("No Munie tasks in this project yet."))
                  .foregroundStyle(.secondary)
              }
              ForEach(tasks) { task in
                NavigationLink(value: task.id) {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.headline).lineLimit(2)
                    RemoteTaskState(task: task)
                    Text(task.updatedAt, format: .dateTime.month().day().hour().minute())
                      .font(.caption).foregroundStyle(.secondary)
                  }
                  .padding(.vertical, 4)
                }
              }
            }
          }
          if status.projects.isEmpty {
            Section {
              Text(
                remoteString("This iPhone has no authorized projects. Choose projects on your Mac.")
              )
            }
          }
        } else if coordinator.model.isBusy {
          ProgressView(remoteString("Reading Mac state…"))
        } else {
          ContentUnavailableView(
            remoteString("Mac state unavailable"), systemImage: "network.slash",
            description: Text(
              remoteString("Refresh to reconnect. Existing work will not be submitted again.")))
        }
      }
      .refreshable { await coordinator.refresh() }
      .safeAreaInset(edge: .bottom) {
        Button(remoteString("Refresh from Mac"), systemImage: "arrow.clockwise") {
          Task { await coordinator.refresh() }
        }
        .disabled(coordinator.model.isBusy)
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
      }
    }
  }

  private struct RemotePairingView: View {
    let coordinator: RemoteCoordinator
    @State private var invitation = ""
    @State private var showScanner = false

    var body: some View {
      Form {
        Section {
          Label(remoteString("Your Mac, with you"), systemImage: "desktopcomputer")
            .font(.title2)
          Text(
            remoteString(
              "Open Munie Host on your Mac, choose a project, and create a pairing invitation. Both devices need the configured secure network connection."
            ))
        }
        Section(remoteString("Pairing invitation")) {
          Button(remoteString("Scan Mac invitation"), systemImage: "qrcode.viewfinder") {
            showScanner = true
          }
          .disabled(coordinator.isPairing)
          TextEditor(text: $invitation)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(minHeight: 130)
            .accessibilityLabel(remoteString("Paste the invitation from your Mac"))
            .accessibilityIdentifier("remote.pair.invitation")
            .disabled(coordinator.isPairing)
          Text(
            remoteString(
              "The invitation is sensitive and expires quickly. Share it only between your own devices."
            )
          )
          .font(.footnote).foregroundStyle(.secondary)
          if coordinator.isPairing {
            ProgressView(remoteString("Waiting for confirmation on your Mac…"))
            if let fingerprint = coordinator.pairingFingerprint {
              Text(remoteString("Compare this fingerprint on your Mac before confirming:"))
              Text(fingerprint).font(.title3.monospaced())
                .accessibilityLabel(remoteString("Pairing fingerprint"))
                .accessibilityValue(fingerprint)
                .accessibilityIdentifier("remote.pair.fingerprint")
            }
            if let id = coordinator.pairingID {
              Text(remoteString("Verify this pairing ID on both devices:"))
              Text(id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityLabel(remoteString("Pairing ID"))
                .accessibilityValue(id.uuidString)
                .accessibilityIdentifier("remote.pair.id")
            }
            Button(remoteString("Cancel pairing"), role: .cancel) { coordinator.cancelPairing() }
          } else {
            Button(remoteString("Request pairing"), systemImage: "link") {
              coordinator.beginPairing(invitationText: invitation)
            }
            .disabled(invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("remote.pair.request")
          }
        }
        Section {
          Text(
            remoteString(
              "Confirm this exact iPhone and its project access on the Mac. Pairing does not approve future Codex commands."
            ))
          Text(
            remoteString(
              "Your Codex account stays on the Mac. The Mac must be awake and reachable to run tasks."
            ))
        }
      }
      .onChange(of: coordinator.hasConnection) { _, connected in if connected { invitation = "" } }
      .sheet(isPresented: $showScanner) {
        PairingQRScanner { payload in
          invitation = payload
          showScanner = false
        }
      }
      .onDisappear {
        coordinator.cancelPairing()
        invitation = ""
      }
    }
  }

  private struct RemoteConnectionSummary: View {
    let coordinator: RemoteCoordinator

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Label(
          coordinator.model.status?.hostName ?? coordinator.endpointLabel,
          systemImage: "desktopcomputer"
        )
        .font(.headline)
        Label(connectionText, systemImage: connectionSymbol)
        if coordinator.model.status?.codexReady == false {
          Text(
            remoteString("Codex is not ready on the Mac. Check its login and service status there.")
          )
          .font(.footnote)
        }
        if let confirmed = coordinator.lastConfirmedAt {
          Text(remoteString("Last confirmed")) + Text(" ")
            + Text(confirmed, format: .dateTime.hour().minute().second())
        }
      }
      .accessibilityElement(children: .combine)
    }

    private var connectionText: String {
      switch coordinator.model.connection {
      case .connected: remoteString("Mac is reachable")
      case .connecting: remoteString("Checking connection…")
      case .unavailable: remoteString("Mac or network is unreachable")
      case .unauthorized: remoteString("Access was denied. Check pairing on the Mac.")
      case .disconnected: remoteString("Not connected")
      }
    }

    private var connectionSymbol: String {
      switch coordinator.model.connection {
      case .connected: "checkmark.circle"
      case .connecting: "arrow.trianglehead.2.clockwise"
      case .unavailable, .unauthorized: "exclamationmark.triangle"
      case .disconnected: "network.slash"
      }
    }
  }

  private struct RemoteTaskState: View {
    let task: RemoteTask
    var body: some View {
      if task.cancellationRequested && !task.phase.isTerminal {
        Label(
          remoteString("Cancellation requested — waiting for Mac confirmation"),
          systemImage: "hourglass"
        )
        .font(.subheadline)
      } else if task.approval != nil {
        Label(remoteString("Needs your approval"), systemImage: "hand.raised")
          .font(.subheadline)
      } else {
        Label(task.phase.displayName, systemImage: symbol).font(.subheadline)
      }
    }
    private var symbol: String {
      switch task.phase {
      case .accepted: "tray.and.arrow.down"
      case .running: "gearshape.2"
      case .reconciling: "arrow.clockwise"
      case .completed: "checkmark.circle"
      case .failed: "exclamationmark.triangle"
      case .cancelled: "stop.circle"
      }
    }
  }

  private struct RemoteConversationView: View {
    let coordinator: RemoteCoordinator
    let taskID: UUID
    @State private var confirmCancel = false

    private var task: RemoteTask? { coordinator.model.status?.tasks.first { $0.id == taskID } }

    var body: some View {
      Group {
        if let task {
          List {
            Section {
              RemoteTaskState(task: task)
              if coordinator.model.connection != .connected {
                Text(remoteString("Showing the last confirmed state. Refresh to check the Mac."))
                  .font(.footnote).foregroundStyle(.secondary)
              }
              if task.phase == .reconciling {
                Text(
                  remoteString("The Mac is checking the existing task. It will not send it again."))
              }
            }
            Section(remoteString("Conversation")) {
              ForEach(task.messages) { message in
                VStack(alignment: .leading, spacing: 6) {
                  Text(message.role == .user ? remoteString("You") : "Codex")
                    .font(.caption).foregroundStyle(.secondary)
                  Text(message.role == .progress ? remoteProgress(message.text) : message.text)
                    .textSelection(.enabled)
                }
                .padding(.vertical, 4)
              }
            }
            if let approval = task.approval {
              RemoteApprovalSection(coordinator: coordinator, task: task, approval: approval)
            }
            if let error = coordinator.model.lastError { Section { RemoteErrorView(error: error) } }
            if coordinator.model.pendingSubmission != nil || coordinator.model.hasUnresolvedRecovery
            {
              Section { RemotePendingSubmissionView(coordinator: coordinator) }
            }
            if task.phase.isTerminal {
              Section(remoteString("Continue this conversation")) {
                RemoteComposer(coordinator: coordinator, projectID: task.projectID, taskID: task.id)
              }
            } else if !task.cancellationRequested {
              Section {
                Button(remoteString("Cancel task"), systemImage: "stop.circle", role: .destructive)
                {
                  confirmCancel = true
                }
                .disabled(coordinator.model.isBusy)
              }
            }
          }
          .navigationTitle(task.title)
          .navigationBarTitleDisplayMode(.inline)
          .refreshable { await coordinator.refresh() }
        } else {
          ContentUnavailableView(
            remoteString("Task unavailable"), systemImage: "questionmark.folder",
            description: Text(
              remoteString(
                "Reconnect to the paired Mac to load this task. No new task has been submitted.")))
        }
      }
      .toolbar {
        Button(remoteString("Refresh from Mac"), systemImage: "arrow.clockwise") {
          Task { await coordinator.refresh() }
        }
        .disabled(coordinator.model.isBusy)
      }
      .confirmationDialog(
        remoteString("Request cancellation on the Mac?"), isPresented: $confirmCancel
      ) {
        Button(remoteString("Cancel task"), role: .destructive) {
          Task { await coordinator.model.cancel(taskID: taskID) }
        }
      } message: {
        Text(
          remoteString(
            "The task is stopped only when the Mac confirms a cancelled result. Completed work is not undone."
          ))
      }
    }
  }

  private struct RemoteApprovalSection: View {
    let coordinator: RemoteCoordinator
    let task: RemoteTask
    let approval: RemoteApproval

    var body: some View {
      Section(remoteString("Review the requested action")) {
        Text(
          remoteString(
            "Approve only if you understand this exact command and its working directory."))
        LabeledContent(remoteString("Command")) {
          Text(approval.command).font(.body.monospaced()).textSelection(.enabled)
        }
        LabeledContent(remoteString("Working directory")) {
          Text(approval.cwd).textSelection(.enabled)
        }
        if let reason = approval.reason { Text(reason).textSelection(.enabled) }
        TimelineView(.periodic(from: .now, by: 1)) { context in
          if approval.expiresAt <= context.date {
            Text(remoteString("This approval expired. Refresh the task before continuing."))
          } else {
            LabeledContent(remoteString("Expires")) {
              Text(approval.expiresAt, style: .relative)
            }
            Button(remoteString("Approve once"), systemImage: "checkmark.shield") {
              Task {
                await coordinator.model.respondApproval(
                  taskID: task.id, approvalID: approval.id, accept: true)
              }
            }
            .disabled(coordinator.model.isBusy || task.cancellationRequested)
            Button(remoteString("Deny action"), systemImage: "xmark.shield", role: .destructive) {
              Task {
                await coordinator.model.respondApproval(
                  taskID: task.id, approvalID: approval.id, accept: false)
              }
            }
            .disabled(coordinator.model.isBusy || task.cancellationRequested)
          }
        }
      }
    }
  }

  private struct RemoteNewTaskView: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: RemoteCoordinator
    let openTask: (UUID) -> Void
    @State private var projectID: UUID?

    var body: some View {
      NavigationStack {
        Form {
          Section(remoteString("Authorized project")) {
            Picker(remoteString("Project"), selection: $projectID) {
              Text(remoteString("Choose a project")).tag(UUID?.none)
              ForEach(coordinator.model.status?.projects ?? []) { project in
                Text(project.name).tag(Optional(project.id))
              }
            }
          }
          if let projectID {
            Section(remoteString("Request")) {
              RemoteComposer(coordinator: coordinator, projectID: projectID, taskID: nil) {
                if let taskID = coordinator.lastSubmittedTaskID {
                  dismiss()
                  openTask(taskID)
                }
              }
            }
          }
          if let error = coordinator.model.lastError { Section { RemoteErrorView(error: error) } }
          if coordinator.model.pendingSubmission != nil || coordinator.model.hasUnresolvedRecovery {
            Section { RemotePendingSubmissionView(coordinator: coordinator) }
          }
        }
        .navigationTitle(remoteString("New task"))
        .toolbar { Button(remoteString("Close"), role: .cancel) { dismiss() } }
        .onAppear {
          if coordinator.model.status?.projects.count == 1 {
            projectID = coordinator.model.status?.projects.first?.id
          }
        }
      }
    }
  }

  private struct RemoteComposer: View {
    @Bindable var coordinator: RemoteCoordinator
    let projectID: UUID
    let taskID: UUID?
    var didSubmit: (() -> Void)?
    @State private var showVoice = false

    var body: some View {
      @Bindable var model = coordinator.model
      Group {
        if taskID != nil,
          let project = model.status?.projects.first(where: { $0.id == projectID })
        {
          LabeledContent(remoteString("Project"), value: project.name)
        }
        TextEditor(text: $model.draft)
          .frame(minHeight: 120)
          .accessibilityLabel(remoteString("Task request"))
          .accessibilityIdentifier("remote.composer")
        Text(
          remoteString(
            "Requests run in this project on your Mac. Review the text before submitting.")
        )
        .font(.footnote).foregroundStyle(.secondary)
        Button(remoteString("Short voice input"), systemImage: "mic") { showVoice = true }
          .accessibilityIdentifier("remote.voice")
        Button(
          taskID == nil ? remoteString("Start task on Mac") : remoteString("Continue on Mac"),
          systemImage: "paperplane"
        ) {
          Task {
            await coordinator.submit(projectID: projectID, taskID: taskID)
            if model.lastError == nil, model.pendingSubmission == nil { didSubmit?() }
          }
        }
        .disabled(
          model.isBusy || model.pendingSubmission != nil || model.hasUnresolvedRecovery
            || model.connection != .connected
            || model.status?.codexReady != true
            || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.draft.utf8.count > 32_768
        )
        .accessibilityIdentifier("remote.submit")
        if model.isBusy { ProgressView(remoteString("Contacting Mac…")) }
      }
      .sheet(isPresented: $showVoice) {
        ShortVoiceInputView { text in
          if !model.draft.isEmpty { model.draft += "\n" }
          model.draft += text
        }
      }
    }
  }

  private struct RemotePendingSubmissionView: View {
    let coordinator: RemoteCoordinator
    @State private var confirmDiscard = false

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        Label(
          remoteString("Submission needs confirmation"),
          systemImage: "exclamationmark.arrow.triangle.2.circlepath"
        )
        .font(.headline)
        if coordinator.model.pendingSubmission == nil {
          Text(
            remoteString(
              "Local recovery input could not be read. Check the Mac task list before discarding this iPhone’s recovery data. New submissions are paused."
            ))
          Button(remoteString("Reload saved recovery input")) {
            Task {
              await coordinator.model.restorePending()
              await coordinator.refresh()
            }
          }
          .disabled(coordinator.model.isBusy)
        } else {
          Text(
            remoteString(
              "Your request is saved on this iPhone. Refresh checks whether the Mac accepted it. Reconnect never sends it automatically."
            ))
        }
        Button(remoteString("Check Mac first")) { Task { await coordinator.refresh() } }
          .disabled(coordinator.model.isBusy)
        if coordinator.model.pendingSubmission != nil {
          Button(remoteString("Retry the same request")) {
            Task { await coordinator.model.retryPending() }
          }
          .disabled(coordinator.model.isBusy || coordinator.model.connection != .connected)
        }
        Button(remoteString("Discard local recovery input"), role: .destructive) {
          confirmDiscard = true
        }
        .disabled(coordinator.model.isBusy)
      }
      .confirmationDialog(
        remoteString("Discard this iPhone’s recovery input?"), isPresented: $confirmDiscard
      ) {
        Button(remoteString("Discard local recovery input"), role: .destructive) {
          Task { await coordinator.model.discardPending() }
        }
      } message: {
        Text(
          remoteString(
            "This does not cancel an accepted Mac task. Check its state before starting another request."
          ))
      }
    }
  }

  private struct RemoteErrorView: View {
    let error: RemoteClientError
    var body: some View {
      Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
    }
    private var message: String {
      switch error {
      case .unauthorized, .remote(.unauthorized):
        remoteString("Access was denied. Check pairing on the Mac.")
      case .busy, .remote(.busy):
        remoteString(
          "A task or request is already in progress. Check its state before trying again.")
      case .remote(.expired):
        remoteString("This approval or pairing expired. Refresh the latest state.")
      case .remote(.conflict):
        remoteString("The Mac rejected a changed or repeated action. Refresh the task.")
      case .persistence, .remote(.storage):
        remoteString("Recovery input could not be saved or read. It has not been submitted again.")
      case .invalidInput, .remote(.invalidRequest):
        remoteString("Check the request. Use 32,768 UTF-8 bytes or fewer.")
      case .invalidEndpoint, .invalidCredential, .unconfigured:
        remoteString("The connection is not configured. Check pairing and the selected project.")
      case .cancelled:
        remoteString("The network request stopped. Refresh to check the Mac’s actual task state.")
      case .disconnected, .remote(.unavailable):
        remoteString("The Mac or network is unreachable. Your input remains available.")
      case .invalidResponse, .responseTooLarge, .remote(.unsupportedVersion),
        .remote(.internalFailure):
        remoteString(
          "The Mac response could not be used. Refresh or check the service on your Mac.")
      }
    }
  }

  private struct RemoteConnectionSettings: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: RemoteCoordinator
    @State private var confirmForget = false

    var body: some View {
      NavigationStack {
        Form {
          if coordinator.hasConnection {
            Section(remoteString("Connection")) {
              RemoteConnectionSummary(coordinator: coordinator)
              Text(coordinator.endpointLabel).textSelection(.enabled)
              Button(remoteString("Refresh from Mac")) { Task { await coordinator.refresh() } }
            }
          }
          Section(remoteString("Task notifications")) {
            if coordinator.notifications.permissionGranted {
              Label(remoteString("System notifications enabled"), systemImage: "checkmark.circle")
            }
            Text(
              remoteString(
                "Munie can notify you when it observes completion, failure, or a pending approval. Alerts hide task content."
              ))
            Text(
              remoteString(
                "Without configured remote push, updates are checked while Munie is open. iOS may suspend the app in the background. Open Munie to recover authoritative state."
              )
            )
            .font(.footnote).foregroundStyle(.secondary)
            Button(remoteString("Enable system notifications")) {
              Task {
                await coordinator.notifications.requestPermission()
                if coordinator.notifications.permissionGranted {
                  UIApplication.shared.registerForRemoteNotifications()
                }
              }
            }
            if let error = coordinator.notifications.errorMessage { Text(error) }
            if let error = RemotePushRegistration.shared.errorMessage { Text(error) }
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
              Link(remoteString("Open iPhone Settings"), destination: settingsURL)
            }
          }
          Section(remoteString("Quick entry")) {
            Text(
              remoteString(
                "Add “New Munie task” in Shortcuts. On supported iPhones, assign that shortcut to the Action button. Unlock to review and submit; the shortcut does not start recording or approve actions."
              ))
          }
          if coordinator.hasConnection {
            Section {
              Button(remoteString("Forget this Mac on iPhone"), role: .destructive) {
                confirmForget = true
              }
              Text(
                remoteString(
                  "This removes the connection from this iPhone. Revoke the device on your Mac to remove its access. Existing Mac work is not cancelled."
                )
              )
              .font(.footnote).foregroundStyle(.secondary)
            }
          }
        }
        .navigationTitle(remoteString("Connection settings"))
        .toolbar { Button(remoteString("Done")) { dismiss() } }
        .confirmationDialog(remoteString("Forget this Mac on iPhone?"), isPresented: $confirmForget)
        {
          Button(remoteString("Forget connection"), role: .destructive) {
            Task {
              await coordinator.forgetConnection()
              dismiss()
            }
          }
        }
      }
    }
  }
#endif
