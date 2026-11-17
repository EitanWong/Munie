#if os(iOS)
  import Foundation
  import MunieRemote
  import Testing

  @testable import Munie

  @MainActor
  struct RemoteCoordinatorTests {
    @Test func connectionPublicationWaitsForTheFirstAuthoritativeProjectRead() async throws {
      let fixture = PairingCompletionFixture()
      let coordinator = RemoteCoordinator(model: fixture.model)
      let completion = Task {
        try await coordinator.completePairing(hostID: fixture.hostID, endpoint: fixture.endpoint)
      }
      defer { completion.cancel() }
      try await fixture.waitForFirstRead()
      // The connected branch removes RemotePairingView and invokes cancelPairing on disappearance.
      // Until the first read finishes, that branch must not be published.
      #expect(!coordinator.hasConnection)
      #expect(coordinator.model.status == nil)
      await fixture.client.release()
      try await completion.value
      #expect(coordinator.hasConnection)
      coordinator.cancelPairing()
      #expect(coordinator.model.connection == .connected)
      #expect(coordinator.model.lastError == nil)
      #expect(coordinator.model.status?.projects.map(\.id) == [fixture.projectID])
      #expect(await fixture.client.operations == [.status])
    }

    @Test func cancelledFirstReadCannotPublishAConnectedViewWithoutProjects() async throws {
      let fixture = PairingCompletionFixture()
      let coordinator = RemoteCoordinator(model: fixture.model)
      let completion = Task {
        try await coordinator.completePairing(hostID: fixture.hostID, endpoint: fixture.endpoint)
      }
      defer { completion.cancel() }
      try await fixture.waitForFirstRead()
      completion.cancel()
      do {
        try await completion.value
        Issue.record("Cancelled pairing completion must throw.")
      } catch is CancellationError {}
      #expect(!coordinator.hasConnection)
      #expect(coordinator.model.status == nil)
      #expect(await fixture.client.operations == [.status])
    }

    @Test func pairingCancellationDuringTheReadPreventsLaterPublication() async throws {
      let fixture = PairingCompletionFixture()
      let coordinator = RemoteCoordinator(model: fixture.model)
      let completion = Task {
        try await coordinator.completePairing(hostID: fixture.hostID, endpoint: fixture.endpoint)
      }
      defer { completion.cancel() }
      try await fixture.waitForFirstRead()
      coordinator.cancelPairing()
      await fixture.client.release()
      do {
        try await completion.value
        Issue.record("The cancelled pairing generation must not publish a connection.")
      } catch is CancellationError {}
      #expect(!coordinator.hasConnection)
      #expect(await fixture.client.operations == [.status])
    }
  }

  @MainActor
  private struct PairingCompletionFixture {
    let hostID = UUID()
    let projectID = UUID()
    let endpoint = URL(string: "https://pairing-fixture.invalid")!
    let client: PairingReadClient
    let model: RemoteModel

    init() {
      client = PairingReadClient(
        status: RemoteStatus(
          hostID: hostID, hostName: "Synthetic Mac",
          projects: [RemoteProject(id: projectID, name: "Synthetic project")],
          tasks: [], codexReady: true))
      model = RemoteModel(client: client)
    }

    func waitForFirstRead() async throws {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(2))
      while !(await client.readStarted) {
        guard clock.now < deadline else { throw PairingFixtureError.readDidNotStart }
        try await Task.sleep(for: .milliseconds(5))
      }
    }
  }

  private actor PairingReadClient: RemoteClient {
    let status: RemoteStatus
    private var released = false
    private(set) var readStarted = false
    private(set) var operations: [RemoteOperation] = []

    init(status: RemoteStatus) { self.status = status }

    func call(_ request: RemoteRequest) async throws -> RemoteResponse {
      operations.append(request.op)
      guard request.op == .status else { throw RemoteClientError.invalidInput }
      readStarted = true
      while !released { try await Task.sleep(for: .milliseconds(5)) }
      try Task.checkCancellation()
      return RemoteResponse(status: status)
    }

    func release() { released = true }
  }

  private enum PairingFixtureError: Error { case readDidNotStart }
#endif
