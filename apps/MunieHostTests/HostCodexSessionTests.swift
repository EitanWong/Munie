import Darwin
import Foundation
import Synchronization
import Testing

@testable import MunieExecutionHost

struct HostCodexSessionTests {
  @Test func claimIsDurableBeforeDispatchAndExactDuplicateNeverReplays() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let request = try fixture.request(text: " Preserve exact text.\n")
    let upstream = fixture.upstream
    let adapter = SessionAdapter(start: { authorized in
      #expect(authorized.request.text.utf8.elementsEqual(request.text.utf8))
      #expect(authorized.workingDirectory.path == fixture.project.path)
      let durable = try await ledger.snapshot(requestID: request.requestID, from: fixture.device)
      #expect(durable.phase == .dispatching)
      #expect(durable.upstream == nil)
      return upstream
    })
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let started = try await session.submit(request, from: fixture.device)
    #expect(started.submission.phase == .running)
    #expect(started.submission.upstream == upstream)
    #expect(
      try await session.submit(request, from: fixture.device).submission == started.submission)
    await #expect(throws: SubmissionError.requestConflict) {
      try await session.submit(
        fixture.request(id: request.requestID, text: "Preserve exact text.\n"), from: fixture.device
      )
    }
    #expect(await adapter.counts().starts == 1)
    #expect(try await session.close().complete)
    #expect(
      try await ledger.snapshot(requestID: request.requestID, from: fixture.device).phase
        == .reconciling)
  }

  @Test func lostStartResponseRemainsUnmappedAndCannotBeResubmitted() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let request = try fixture.request()
    do {
      let ledger = try await fixture.ledger()
      let adapter = SessionAdapter(start: { _ in throw SessionFailure.disconnected })
      let session = try HostCodexSession(ledger: ledger, adapter: adapter)
      await #expect(throws: SessionFailure.disconnected) {
        try await session.submit(request, from: fixture.device)
      }
      let unknown = try await session.submit(request, from: fixture.device)
      #expect(unknown.submission.phase == .reconciling)
      #expect(unknown.submission.upstream == nil)
      #expect(await adapter.counts().starts == 1)
      _ = try await session.close()
    }
    let ledger = try fixture.reopen()
    let adapter = SessionAdapter()
    let reopened = try HostCodexSession(ledger: ledger, adapter: adapter)
    #expect(
      try await reopened.submit(request, from: fixture.device).submission.phase == .reconciling)
    #expect(
      try await reopened.reconcile(requestID: request.requestID, from: fixture.device).submission
        .upstream == nil)
    #expect(await adapter.counts().starts == 0)
    #expect(await adapter.counts().reads == 0)
    await #expect(throws: HostCodexSessionError.busy) {
      try await reopened.submit(fixture.request(), from: fixture.device)
    }
    _ = try await reopened.close()
  }

  @Test func reservationPrecedesSuspensionButDuplicateCanReadDispatching() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let entered = SessionGate()
    let release = SessionGate()
    let adapter = SessionAdapter(start: { _ in
      await entered.open()
      await release.wait()
      return fixture.upstream
    })
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    let sending = Task { try await session.submit(request, from: fixture.device) }
    await entered.wait()
    await #expect(throws: HostCodexSessionError.busy) {
      try await session.submit(fixture.request(), from: fixture.device)
    }
    await #expect(throws: HostCodexSessionError.operationInProgress) {
      try await session.reconcile(requestID: request.requestID, from: fixture.device)
    }
    #expect(
      try await session.submit(request, from: fixture.device).submission.phase == .dispatching)
    await release.open()
    #expect(try await sending.value.submission.phase == .running)
    #expect(await adapter.counts().starts == 1)
    _ = try await session.close()
  }

  @Test(arguments: [CodexTurnStatus.completed, .failed, .interrupted])
  func matchingTerminalPersistsAndReleasesSession(status: CodexTurnStatus) async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream)
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    await adapter.enqueue(fixture.terminal(request, status: status))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    let expected: SubmissionPhase =
      status == .completed ? .completed : status == .failed ? .failed : .cancelled
    #expect(
      try await session.snapshot(requestID: request.requestID, from: fixture.device).submission
        .phase == expected)
    // A different upstream is needed because ledger identity is unique across native turns.
    await adapter.setUpstream(UpstreamTurn(threadID: UUID(), turnID: UUID()))
    let next = try fixture.request()
    #expect(try await session.submit(next, from: fixture.device).submission.phase == .running)
    #expect(
      try await session.snapshot(requestID: request.requestID, from: fixture.device).submission
        .phase == expected)
    _ = try await session.close()
  }

  @Test func wrongNativeIdentityAndNonterminalTerminalEventPreserveUncertainty() async throws {
    for variant in 0..<4 {
      let fixture = try SessionFixture()
      defer { fixture.remove() }
      let ledger = try await fixture.ledger()
      let adapter = SessionAdapter(upstream: fixture.upstream)
      let session = try HostCodexSession(ledger: ledger, adapter: adapter)
      let request = try fixture.request()
      _ = try await session.submit(request, from: fixture.device)
      let wrong = UpstreamTurn(threadID: fixture.upstream.threadID, turnID: UUID())
      await adapter.enqueue(
        CodexNativeEvent(
          method: "turn/completed", requestID: variant == 0 ? UUID() : request.requestID,
          threadID: variant == 1 ? UUID() : fixture.upstream.threadID,
          turnID: fixture.upstream.turnID,
          kind: .terminal(
            CodexTurnSnapshot(
              upstream: variant == 2 ? wrong : fixture.upstream,
              status: variant == 3 ? .inProgress : .completed)), payload: .object([:])))
      await #expect(throws: HostCodexSessionError.mismatchedEvent) {
        try await session.nextEvent(requestID: request.requestID, from: fixture.device)
      }
      #expect(
        try await session.snapshot(requestID: request.requestID, from: fixture.device).submission
          .phase == .reconciling)
      _ = try await session.close()
    }
  }

  @Test func oneEventConsumerAllowsConcurrentInterruptButEOFIsNotCancellation() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream)
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    let reading = Task {
      try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    }
    await adapter.eventEntered.wait()
    await #expect(throws: HostCodexSessionError.operationInProgress) {
      try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    }
    let acknowledged = try await session.interrupt(
      requestID: request.requestID, from: fixture.device)
    #expect(acknowledged.submission.phase == .running)
    #expect(acknowledged.cancellationRequested)
    _ = try await session.interrupt(requestID: request.requestID, from: fixture.device)
    #expect(await adapter.counts().interrupts == 1)
    await adapter.failEvent(.disconnected)
    await #expect(throws: SessionFailure.disconnected) { try await reading.value }
    #expect(
      try await session.snapshot(requestID: request.requestID, from: fixture.device).submission
        .phase == .reconciling)
    _ = try await session.close()
  }

  @Test func approvalBindsExactActionAndIsAnsweredOnceUntilNativeResolution() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream)
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    let approval = fixture.approval()
    await adapter.enqueue(fixture.approvalEvent(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    #expect(
      try await session.snapshot(requestID: request.requestID, from: fixture.device).pendingApproval
        == approval)
    let altered = fixture.approval(command: "different action")
    await #expect(throws: HostCodexSessionError.staleApproval) {
      try await session.respondApproval(
        requestID: request.requestID, approval: altered, decision: .accept, from: fixture.device)
    }
    let answered = try await session.respondApproval(
      requestID: request.requestID, approval: approval, decision: .accept, from: fixture.device)
    #expect(answered.submission.phase == .running)
    #expect(answered.pendingApproval == nil)
    await #expect(throws: HostCodexSessionError.staleApproval) {
      try await session.respondApproval(
        requestID: request.requestID, approval: approval, decision: .accept, from: fixture.device)
    }
    #expect(await adapter.counts().responses == 1)
    await adapter.enqueue(fixture.resolved(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    #expect(
      try await session.snapshot(requestID: request.requestID, from: fixture.device).submission
        .phase == .running)
    await adapter.enqueue(fixture.terminal(request, status: .completed))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    _ = try await session.close()
  }

  @Test func approvalRejectsUnavailableDecisionAndExpiresWithoutAnswering() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream)
    let clock = SessionTime()
    let session = try HostCodexSession(ledger: ledger, adapter: adapter, now: { clock.now })
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    let approval = fixture.approval(decisions: [.string("cancel")])
    await adapter.enqueue(fixture.approvalEvent(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    await #expect(throws: HostCodexSessionError.unavailableDecision) {
      try await session.respondApproval(
        requestID: request.requestID, approval: approval, decision: .accept, from: fixture.device)
    }
    clock.advance()
    #expect(
      try await session.snapshot(requestID: request.requestID, from: fixture.device).pendingApproval
        == nil)
    await #expect(throws: HostCodexSessionError.expiredApproval) {
      try await session.respondApproval(
        requestID: request.requestID, approval: approval, decision: .cancel, from: fixture.device)
    }
    #expect(await adapter.counts().responses == 0)
    // Expiry invalidates host answering, while the matching native resolution is still consumed.
    await adapter.enqueue(fixture.resolved(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    _ = try await session.close()
  }

  @Test func approvalActionMustPreserveExactUTF8DespiteStringEquivalence() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream)
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    let approval = fixture.approval(command: "é")
    await adapter.enqueue(fixture.approvalEvent(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    let altered = fixture.approval(command: "e\u{301}")
    #expect(approval.command == altered.command)
    await #expect(throws: HostCodexSessionError.staleApproval) {
      try await session.respondApproval(
        requestID: request.requestID, approval: altered, decision: .accept, from: fixture.device)
    }
    #expect(await adapter.counts().responses == 0)
    _ = try await session.respondApproval(
      requestID: request.requestID, approval: approval, decision: .accept, from: fixture.device)
    _ = try await session.close()
  }

  @Test func concurrentApprovalAnswerAndNativeResolutionRemainNonterminal() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let entered = SessionGate()
    let release = SessionGate()
    let adapter = SessionAdapter(
      upstream: fixture.upstream,
      respond: { _, _ in
        await entered.open()
        await release.wait()
      })
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    let approval = fixture.approval()
    await adapter.enqueue(fixture.approvalEvent(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    let answering = Task {
      try await session.respondApproval(
        requestID: request.requestID, approval: approval, decision: .accept, from: fixture.device)
    }
    await entered.wait()
    await #expect(throws: HostCodexSessionError.staleApproval) {
      try await session.respondApproval(
        requestID: request.requestID, approval: approval, decision: .accept, from: fixture.device)
    }
    await adapter.enqueue(fixture.resolved(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    #expect(
      try await session.snapshot(requestID: request.requestID, from: fixture.device).submission
        .phase == .running)
    await adapter.enqueue(fixture.terminal(request, status: .completed))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    await release.open()
    #expect(try await answering.value.submission.phase == .completed)
    #expect(await adapter.counts().responses == 1)
    _ = try await session.close()
  }

  @Test func reconcileDoesNotDetachActiveRunningEventStream() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream)
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    #expect(
      try await session.reconcile(requestID: request.requestID, from: fixture.device).submission
        .phase == .running)
    await adapter.enqueue(fixture.terminal(request, status: .completed))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    #expect(await adapter.counts().reads == 0)
    _ = try await session.close()
  }

  @Test(arguments: [false, true])
  func newSessionOnSameLedgerRequiresExactReadWithoutResending(reconcileDirectly: Bool) async throws
  {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let originalAdapter = SessionAdapter(upstream: fixture.upstream)
    let original = try HostCodexSession(ledger: ledger, adapter: originalAdapter)
    let request = try fixture.request()
    _ = try await original.submit(request, from: fixture.device)
    let nextAdapter = SessionAdapter(read: { upstream in
      CodexTurnSnapshot(upstream: upstream, status: .completed)
    })
    let next = try HostCodexSession(ledger: ledger, adapter: nextAdapter)
    if !reconcileDirectly {
      #expect(try await next.submit(request, from: fixture.device).submission.phase == .reconciling)
      #expect(await nextAdapter.counts().reads == 0)
      await #expect(throws: HostCodexSessionError.busy) {
        try await next.submit(fixture.request(), from: fixture.device)
      }
    }
    #expect(
      try await next.reconcile(requestID: request.requestID, from: fixture.device).submission.phase
        == .completed)
    #expect(await nextAdapter.counts().starts == 0)
    #expect(await nextAdapter.counts().reads == 1)
    // The original event owner sees the same positive terminal before cleanup; no replay occurs.
    await originalAdapter.enqueue(fixture.terminal(request, status: .completed))
    _ = try await original.nextEvent(requestID: request.requestID, from: fixture.device)
    #expect(await originalAdapter.counts().starts == 1)
    _ = try await next.close()
    _ = try await original.close()
  }

  @Test func externalTerminalInvalidatesLocalApprovalAndInterrupt() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream)
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    let approval = fixture.approval()
    await adapter.enqueue(fixture.approvalEvent(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    try await ledger.observeTerminal(
      requestID: request.requestID, upstream: fixture.upstream, phase: .completed)
    #expect(
      try await session.snapshot(requestID: request.requestID, from: fixture.device).pendingApproval
        == nil)
    await #expect(throws: HostCodexSessionError.staleApproval) {
      try await session.respondApproval(
        requestID: request.requestID, approval: approval, decision: .accept, from: fixture.device)
    }
    await #expect(throws: HostCodexSessionError.noActiveTask) {
      try await session.interrupt(requestID: request.requestID, from: fixture.device)
    }
    #expect(await adapter.counts().responses == 0)
    #expect(await adapter.counts().interrupts == 0)
    await adapter.enqueue(fixture.terminal(request, status: .completed))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    _ = try await session.close()
  }

  @Test func approvalOutsideClaimedDirectoryIsNotExposed() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream)
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    await adapter.enqueue(fixture.approvalEvent(request, fixture.approval(directory: "/untrusted")))
    await #expect(throws: HostCodexSessionError.mismatchedEvent) {
      try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    }
    let state = try await session.snapshot(requestID: request.requestID, from: fixture.device)
    #expect(state.pendingApproval == nil)
    #expect(state.submission.phase == .reconciling)
    _ = try await session.close()
  }

  @Test func interruptInvalidatesApprovalButAcknowledgementNeedsNativeTerminal() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream)
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    let approval = fixture.approval()
    await adapter.enqueue(fixture.approvalEvent(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    let interrupted = try await session.interrupt(
      requestID: request.requestID, from: fixture.device)
    #expect(interrupted.pendingApproval == nil)
    #expect(interrupted.submission.phase == .running)
    await #expect(throws: HostCodexSessionError.staleApproval) {
      try await session.respondApproval(
        requestID: request.requestID, approval: approval, decision: .accept, from: fixture.device)
    }
    await adapter.enqueue(fixture.resolved(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    await adapter.enqueue(fixture.terminal(request, status: .interrupted))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    #expect(
      try await session.snapshot(requestID: request.requestID, from: fixture.device).submission
        .phase == .cancelled)
    #expect(await adapter.counts().responses == 0)
    _ = try await session.close()
  }

  @Test(arguments: [false, true])
  func lateControlAcknowledgementOrErrorCannotRegressTerminal(failControl: Bool) async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let entered = SessionGate()
    let release = SessionGate()
    let adapter = SessionAdapter(
      upstream: fixture.upstream,
      interrupt: { _ in
        await entered.open()
        await release.wait()
        if failControl { throw SessionFailure.disconnected }
      })
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    let interrupting = Task {
      try await session.interrupt(requestID: request.requestID, from: fixture.device)
    }
    await entered.wait()
    await adapter.enqueue(fixture.terminal(request, status: .completed))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    await release.open()
    if failControl {
      await #expect(throws: SessionFailure.disconnected) { try await interrupting.value }
    } else {
      #expect(try await interrupting.value.submission.phase == .completed)
    }
    #expect(
      try await session.snapshot(requestID: request.requestID, from: fixture.device).submission
        .phase == .completed)
    _ = try await session.close()
  }

  @Test func revocationPreventsSubmitReadApprovalAndInterrupt() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream)
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    let approval = fixture.approval()
    await adapter.enqueue(fixture.approvalEvent(request, approval))
    _ = try await session.nextEvent(requestID: request.requestID, from: fixture.device)
    try await ledger.revokeDevice(id: fixture.device.id)
    await #expect(throws: SubmissionError.unauthorized) {
      try await session.submit(request, from: fixture.device)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await session.snapshot(requestID: request.requestID, from: fixture.device)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await session.respondApproval(
        requestID: request.requestID, approval: approval, decision: .accept, from: fixture.device)
    }
    await #expect(throws: SubmissionError.unauthorized) {
      try await session.interrupt(requestID: request.requestID, from: fixture.device)
    }
    #expect(await adapter.counts().responses == 0)
    #expect(await adapter.counts().interrupts == 0)
    _ = try await session.close()
  }

  @Test func revocationDuringReceiveSuppressesPayloadAndMarksUncertain() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    do {
      let ledger = try await fixture.ledger()
      let adapter = SessionAdapter(upstream: fixture.upstream)
      let session = try HostCodexSession(ledger: ledger, adapter: adapter)
      let request = try fixture.request()
      _ = try await session.submit(request, from: fixture.device)
      let reading = Task {
        try await session.nextEvent(requestID: request.requestID, from: fixture.device)
      }
      await adapter.eventEntered.wait()
      try await ledger.revokeDevice(id: fixture.device.id)
      await adapter.enqueue(fixture.terminal(request, status: .completed))
      await #expect(throws: SubmissionError.unauthorized) { try await reading.value }
      _ = try await session.close()
    }
    // Inspect only phase metadata through test storage; no revoked-device read bypass exists in API.
    #expect(try fixture.phase() == "reconciling")
  }

  @Test(arguments: [false, true])
  func resumedExactHistoryOnlyCompletesOnPositiveTerminal(terminal: Bool) async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let request = try fixture.request()
    try await fixture.seedRunning(request)
    let ledger = try fixture.reopen()
    let adapter = SessionAdapter(read: { upstream in
      #expect(upstream == fixture.upstream)
      return CodexTurnSnapshot(upstream: upstream, status: terminal ? .completed : .inProgress)
    })
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    #expect(
      try await session.submit(request, from: fixture.device).submission.phase == .reconciling)
    let state = try await session.reconcile(requestID: request.requestID, from: fixture.device)
    #expect(state.submission.phase == (terminal ? .completed : .reconciling))
    #expect(state.pendingApproval == nil)
    #expect(!state.cancellationRequested)
    #expect(await adapter.counts().starts == 0)
    #expect(await adapter.counts().reads == 1)
    _ = try await session.close()
  }

  @Test func absentAndMismatchedHistoryNeverResolveOrResend() async throws {
    for mismatch in [false, true] {
      let fixture = try SessionFixture()
      defer { fixture.remove() }
      let request = try fixture.request()
      try await fixture.seedRunning(request)
      let ledger = try fixture.reopen()
      let adapter = SessionAdapter(read: { _ in
        mismatch
          ? CodexTurnSnapshot(
            upstream: UpstreamTurn(threadID: UUID(), turnID: UUID()), status: .completed) : nil
      })
      let session = try HostCodexSession(ledger: ledger, adapter: adapter)
      if mismatch {
        await #expect(throws: HostCodexSessionError.mismatchedEvent) {
          try await session.reconcile(requestID: request.requestID, from: fixture.device)
        }
      } else {
        #expect(
          try await session.reconcile(requestID: request.requestID, from: fixture.device).submission
            .phase == .reconciling)
      }
      #expect(
        try await session.submit(request, from: fixture.device).submission.phase == .reconciling)
      #expect(await adapter.counts().starts == 0)
      _ = try await session.close()
    }
  }

  @Test func absentReadStillRevalidatesRevocationAfterAwait() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let request = try fixture.request()
    try await fixture.seedRunning(request)
    let ledger = try fixture.reopen()
    let entered = SessionGate()
    let release = SessionGate()
    let adapter = SessionAdapter(read: { _ in
      await entered.open()
      await release.wait()
      return nil
    })
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let reading = Task {
      try await session.reconcile(requestID: request.requestID, from: fixture.device)
    }
    await entered.wait()
    try await ledger.revokeDevice(id: fixture.device.id)
    await release.open()
    await #expect(throws: SubmissionError.unauthorized) { try await reading.value }
    _ = try await session.close()
  }

  @Test func closeDuringStartPersistsLateMappingWithoutReplaying() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let entered = SessionGate()
    let release = SessionGate()
    let adapter = SessionAdapter(start: { _ in
      await entered.open()
      await release.wait()
      return fixture.upstream
    })
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    let starting = Task { try await session.submit(request, from: fixture.device) }
    await entered.wait()
    #expect(try await session.close().complete)
    await release.open()
    await #expect(throws: HostCodexSessionError.closed) { try await starting.value }
    let state = try await ledger.snapshot(requestID: request.requestID, from: fixture.device)
    #expect(state.phase == .reconciling)
    #expect(state.upstream == fixture.upstream)
    #expect(await adapter.counts().starts == 1)
    #expect(try await session.close().complete)
    #expect(await adapter.counts().closes == 1)
  }

  @Test func closeFailureRetainsStructuralCauseAndCanRetryCleanup() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let ledger = try await fixture.ledger()
    let adapter = SessionAdapter(upstream: fixture.upstream, closeFailure: true)
    let session = try HostCodexSession(ledger: ledger, adapter: adapter)
    let request = try fixture.request()
    _ = try await session.submit(request, from: fixture.device)
    do {
      _ = try await session.close()
      Issue.record("Failed transport cleanup was accepted")
    } catch let failure as HostCodexCloseFailure {
      #expect(failure.transportError as? SessionFailure == .disconnected)
      #expect(failure.persistenceError == nil)
      #expect(failure.cleanup == nil)
    }
    #expect(
      try await ledger.snapshot(requestID: request.requestID, from: fixture.device).phase
        == .reconciling)
    await adapter.allowClose()
    #expect(try await session.close().complete)
    await #expect(throws: HostCodexSessionError.closed) {
      try await session.snapshot(requestID: request.requestID, from: fixture.device)
    }
  }
}

private enum SessionFailure: Error, Equatable { case disconnected }

private actor SessionGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    opened = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

private final class SessionTime: Sendable {
  private let instant = Mutex(ContinuousClock().now)
  var now: ContinuousClock.Instant { instant.withLock { $0 } }
  func advance() { instant.withLock { $0 = $0.advanced(by: .seconds(61)) } }
}

private struct SessionCounts: Sendable {
  var starts = 0
  var reads = 0
  var responses = 0
  var interrupts = 0
  var closes = 0
}

private actor SessionAdapter: CodexExecutionAdapter {
  let eventEntered = SessionGate()
  private var upstream: UpstreamTurn
  private let startHook: (@Sendable (AuthorizedSubmission) async throws -> UpstreamTurn)?
  private let readHook: (@Sendable (UpstreamTurn) async throws -> CodexTurnSnapshot?)?
  private let interruptHook: (@Sendable (UpstreamTurn) async throws -> Void)?
  private let respondHook:
    (@Sendable (CodexCommandApproval, CodexApprovalDecision) async throws -> Void)?
  private var closeFailure: Bool
  private var recorded = SessionCounts()
  private var events: [Result<CodexNativeEvent, SessionFailure>] = []
  private var waiter: CheckedContinuation<CodexNativeEvent, any Error>?

  init(
    upstream: UpstreamTurn = UpstreamTurn(threadID: UUID(), turnID: UUID()),
    start: (@Sendable (AuthorizedSubmission) async throws -> UpstreamTurn)? = nil,
    read: (@Sendable (UpstreamTurn) async throws -> CodexTurnSnapshot?)? = nil,
    interrupt: (@Sendable (UpstreamTurn) async throws -> Void)? = nil,
    respond: (@Sendable (CodexCommandApproval, CodexApprovalDecision) async throws -> Void)? = nil,
    closeFailure: Bool = false
  ) {
    self.upstream = upstream
    startHook = start
    readHook = read
    interruptHook = interrupt
    respondHook = respond
    self.closeFailure = closeFailure
  }
  func start(_ submission: AuthorizedSubmission) async throws -> UpstreamTurn {
    recorded.starts += 1
    if let startHook { return try await startHook(submission) }
    return upstream
  }
  func nextEvent() async throws -> CodexNativeEvent {
    await eventEntered.open()
    if !events.isEmpty { return try events.removeFirst().get() }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }
  func interrupt(_ upstream: UpstreamTurn) async throws {
    recorded.interrupts += 1
    if let interruptHook { try await interruptHook(upstream) }
  }
  func read(_ upstream: UpstreamTurn) async throws -> CodexTurnSnapshot? {
    recorded.reads += 1
    return try await readHook?(upstream)
  }
  func respondApproval(_ approval: CodexCommandApproval, decision: CodexApprovalDecision)
    async throws
  {
    recorded.responses += 1
    if let respondHook { try await respondHook(approval, decision) }
  }
  func close() async throws -> CodexTransportCleanup {
    recorded.closes += 1
    if closeFailure { throw SessionFailure.disconnected }
    waiter?.resume(throwing: SessionFailure.disconnected)
    waiter = nil
    return CodexTransportCleanup(
      leaderExitStatus: 0, stdoutEOF: true, stderrEOF: true, groupGone: true,
      escalated: false, stdinBytes: 0, stdoutBytes: 0, stderrBytes: 0)
  }
  func enqueue(_ event: CodexNativeEvent) { deliver(.success(event)) }
  func failEvent(_ failure: SessionFailure) { deliver(.failure(failure)) }
  func counts() -> SessionCounts { recorded }
  func setUpstream(_ upstream: UpstreamTurn) { self.upstream = upstream }
  func allowClose() { closeFailure = false }
  private func deliver(_ result: Result<CodexNativeEvent, SessionFailure>) {
    if let waiter {
      self.waiter = nil
      waiter.resume(with: result.mapError { $0 as any Error })
    } else {
      events.append(result)
    }
  }
}

private struct SessionFixture: Sendable {
  let root: URL
  let project: URL
  let store: URL
  let hostID = UUID()
  let projectID = UUID()
  let device = AuthenticatedDevice(id: UUID())
  let upstream = UpstreamTurn(threadID: UUID(), turnID: UUID())

  init() throws {
    guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw CocoaError(.fileReadUnknown)
    }
    defer { free(canonical) }
    root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
      .appendingPathComponent("munie-session-\(UUID().uuidString)", isDirectory: true)
    project = root.appendingPathComponent("project", isDirectory: true)
    store = root.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  }
  func ledger() async throws -> HostSubmissionLedger {
    let ledger = try reopen()
    try await ledger.registerProject(id: projectID, directoryURL: project)
    try await ledger.authorizeDevice(id: device.id, projects: [projectID])
    return ledger
  }
  func reopen() throws -> HostSubmissionLedger {
    try HostSubmissionLedger(directoryURL: store, hostID: hostID)
  }
  func request(id: UUID = UUID(), text: String = "Synthetic coordinator request") throws
    -> TextSubmission
  {
    try TextSubmission(requestID: id, hostID: hostID, projectID: projectID, text: text)
  }
  func approval(
    directory: String? = nil, command: String = "synthetic-command",
    decisions: [CodexJSON] = [.string("accept"), .string("cancel")]
  ) -> CodexCommandApproval {
    CodexCommandApproval(
      rpcID: .integer(7), upstream: upstream, itemID: "synthetic-item", command: command,
      workingDirectory: directory ?? project.path, reason: "Synthetic reason",
      availableDecisions: decisions, payload: .object(["private": .string("host-only action")]))
  }
  func approvalEvent(_ request: TextSubmission, _ approval: CodexCommandApproval)
    -> CodexNativeEvent
  {
    CodexNativeEvent(
      method: "item/commandExecution/requestApproval", requestID: request.requestID,
      threadID: upstream.threadID, turnID: upstream.turnID, itemID: approval.itemID,
      kind: .approval(approval), payload: approval.payload)
  }
  func resolved(_ request: TextSubmission, _ approval: CodexCommandApproval) -> CodexNativeEvent {
    CodexNativeEvent(
      method: "serverRequest/resolved", requestID: request.requestID,
      threadID: upstream.threadID, turnID: upstream.turnID, itemID: approval.itemID,
      kind: .approvalResolved(approval.rpcID), payload: .object([:]))
  }
  func terminal(_ request: TextSubmission, status: CodexTurnStatus) -> CodexNativeEvent {
    CodexNativeEvent(
      method: "turn/completed", requestID: request.requestID,
      threadID: upstream.threadID, turnID: upstream.turnID,
      kind: .terminal(CodexTurnSnapshot(upstream: upstream, status: status)), payload: .object([:]))
  }
  func seedRunning(_ request: TextSubmission) async throws {
    let ledger = try await ledger()
    _ = try await ledger.accept(request, from: device)
    _ = try await ledger.claimForDispatch(request, from: device)
    try await ledger.observeStarted(requestID: request.requestID, upstream: upstream)
  }
  func phase() throws -> String? {
    let database = try SQLiteStorage(directoryURL: store)
    guard case .text(let phase) = try database.rows("SELECT phase FROM requests").first?.first
    else {
      return nil
    }
    return phase
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
