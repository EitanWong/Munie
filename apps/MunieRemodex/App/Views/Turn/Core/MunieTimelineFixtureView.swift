// Munie modification: opt-in deterministic UI fixture exercising the actual upstream timeline without a network or model.
#if DEBUG
  import SwiftUI

  struct MunieTimelineFixtureView: View {
    @State private var messages: [CodexMessage]
    @State private var changeToken = 0
    private let streams: Bool
    private let threadID = "munie-ui-fixture-thread"

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
      let countIndex = arguments.firstIndex(of: "-CodexUITestsMessageCount")
      let requestedCount =
        countIndex.flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
        ?? 40
      let count = max(1, min(requestedCount, 1500))
      self.streams = arguments.contains("-CodexUITestsAutoStream")
      _messages = State(
        initialValue: (0..<count).map { index in
          let role: CodexMessageRole = index.isMultiple(of: 2) ? .user : .assistant
          return CodexMessage(
            id: "fixture-message-\(index)", threadId: "munie-ui-fixture-thread", role: role,
            text: role == .user
              ? "Fixture request \(index)"
              : "## Fixture result \(index)\n\n**Markdown** and `inline code`.\n\n```swift\nlet value = \(index)\n```\n\nMUNIE_TIMELINE_FIXTURE",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            turnId: "fixture-turn-\(index / 2)", orderIndex: index
          )
        })
    }

    var body: some View {
      NavigationStack {
        TurnTimelineView(
          threadID: threadID, messages: messages, timelineChangeToken: changeToken,
          activeTurnID: streams ? "fixture-stream" : nil, isThreadRunning: streams,
          runStartGeneration: 0, isSendInFlight: false, latestTurnTerminalState: .completed,
          completedTurnIDs: Set(messages.compactMap(\.turnId)), stoppedTurnIDs: [],
          assistantRevertStatesByMessageID: [:], planSessionSource: nil,
          allowsAssistantPlanFallbackRecovery: false, threadMessagesForPlanMatching: messages,
          currentWorkingDirectory: nil, isRetryAvailable: false, errorMessage: nil,
          hidesErrorMessage: false, onReportError: { _ in }, onDismissError: {},
          hasRemoteEarlierMessages: false, hasLocallyProjectedEarlierMessages: false,
          usesPaginatedHistory: false, initialTurnsLoaded: true,
          isLoadingRemoteEarlierMessages: false, olderHistoryLoadErrorMessage: nil,
          isAwaitingAssistantResponse: .constant(false), isComposerFocused: false,
          isComposerAutocompletePresented: false, onRetryUserMessage: { _ in },
          onTapAssistantRevert: { _ in }, onTapSubagent: { _ in },
          onRevealEarlierMessages: { _ in }, onLoadRemoteEarlierMessages: {},
          onRetryEarlierMessages: { completion in completion() }, onTapOutsideComposer: {},
          emptyState: { EmptyView() }, composer: { EmptyView() }
        )
        .navigationTitle("UI fixture")
        .task {
          guard streams else { return }
          messages.append(
            CodexMessage(
              id: "fixture-stream", threadId: threadID, role: .assistant, text: "Streaming fixture",
              turnId: "fixture-stream", isStreaming: true, orderIndex: messages.count))
          for index in 0..<40 {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let last = messages.indices.last else { return }
            messages[last].text += " delta-\(index)"
            changeToken += 1
          }
        }
      }
    }
  }
#endif
