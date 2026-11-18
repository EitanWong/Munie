import Combine
import Foundation
@preconcurrency import MultipeerConnectivity

@MainActor
public final class NearbyPairingHost: NSObject, ObservableObject {
  public static let serviceType = "munie-pair"
  @Published public private(set) var state: NearbyPairingHostState = .idle
  @Published public private(set) var pendingRequest: NearbyPairingRequest?
  @Published public private(set) var errorMessage: String?
  private var advertiser: MCNearbyServiceAdvertiser?
  private var session: MCSession?
  private var sessionDelegate: NearbySessionDelegate?
  private var exchange: NearbyPairingExchange?
  private var approvedPayload: Data?
  private var expectedPeer: MCPeerID?
  private var generation = UUID()
  private var timeoutTask: Task<Void, Never>?
  private var hostName = "Mac"
  nonisolated private let callbackAdmission = NearbyCallbackAdmission(maximumPerMinute: 8)

  public override init() { super.init() }

  public func start(hostName: String) throws {
    stop()
    guard NearbyPairingExchange.validName(hostName) else {
      throw NearbyPairingError.invalidMessage
    }
    self.hostName = hostName
    let advertiser = MCNearbyServiceAdvertiser(
      peer: MCPeerID(displayName: hostName), discoveryInfo: ["v": "1"],
      serviceType: Self.serviceType)
    self.advertiser = advertiser
    callbackAdmission.activate(advertiser)
    advertiser.delegate = self
    advertiser.startAdvertisingPeer()
    state = .advertising
  }

  public func stop() {
    callbackAdmission.invalidate()
    generation = UUID()
    timeoutTask?.cancel()
    timeoutTask = nil
    advertiser?.delegate = nil
    advertiser?.stopAdvertisingPeer()
    advertiser = nil
    clearSession()
    state = .idle
    errorMessage = nil
  }

  /// Records Mac approval. Release waits for the iPhone's explicit code confirmation too.
  public func approve(requestID: UUID, payload: Data) throws {
    guard let pendingRequest, pendingRequest.id == requestID, var exchange else {
      throw NearbyPairingError.invalidState
    }
    guard !payload.isEmpty, payload.count <= NearbyPairingExchange.maximumPayloadBytes else {
      throw NearbyPairingError.payloadTooLarge
    }
    if !exchange.localConfirmed { _ = try exchange.confirm() }
    self.exchange = exchange
    approvedPayload = payload
    try deliverIfConfirmed()
  }

  public func reject(requestID: UUID) {
    guard pendingRequest?.id == requestID else { return }
    finishAttempt()
  }

  private func accept(
    _ peer: MCPeerID, context: Data?,
    handler: @escaping (Bool, MCSession?) -> Void
  ) {
    guard advertiser != nil, session == nil, let context, context.count <= 256,
      let invitation = try? JSONDecoder().decode(NearbyInvitation.self, from: context),
      invitation.version == 1
    else {
      handler(false, nil)
      return
    }
    do {
      exchange = try NearbyPairingExchange(
        role: .host, requestID: invitation.requestID, name: hostName)
      let session = MCSession(
        peer: advertiser!.myPeerID, securityIdentity: nil, encryptionPreference: .required)
      generation = UUID()
      let delegate = NearbySessionDelegate(generation: generation, expectedPeer: peer) {
        [weak self] token, event in
        self?.receive(token, event)
      }
      self.session = session
      sessionDelegate = delegate
      session.delegate = delegate
      expectedPeer = peer
      state = .awaitingConfirmation
      errorMessage = nil
      scheduleTimeout()
      handler(true, session)
    } catch {
      handler(false, nil)
      fail()
    }
  }

  private func receive(_ token: UUID, _ event: NearbySessionDelegate.Event) {
    guard token == generation, expectedPeer != nil, session != nil else { return }
    do {
      switch event {
      case .state(let value):
        if value == MCSessionState.connected.rawValue {
          guard let exchange else { throw NearbyPairingError.invalidState }
          try send(exchange.commitment())
        } else if value == MCSessionState.notConnected.rawValue {
          finishAttempt()
        }
      case .data(let data):
        guard var exchange else {
          throw NearbyPairingError.invalidMessage
        }
        let response = try exchange.receiveHandshake(data)
        self.exchange = exchange
        if let response { try send(response) }
        if let code = exchange.verificationCode, let deviceName = exchange.remoteName {
          pendingRequest = NearbyPairingRequest(
            id: exchange.requestID, deviceName: deviceName, verificationCode: code,
            phoneConfirmed: exchange.remoteConfirmed)
        }
        try deliverIfConfirmed()
      case .unsupportedTransfer:
        throw NearbyPairingError.invalidMessage
      }
    } catch { fail() }
  }

  private func deliverIfConfirmed() throws {
    guard var exchange, exchange.localConfirmed, exchange.remoteConfirmed,
      let approvedPayload
    else { return }
    let message = try exchange.sealPayload(approvedPayload)
    try send(message)
    self.exchange = exchange
    self.approvedPayload = nil
    pendingRequest = nil
    state = .connected
    // Keep the reliable session alive until the client closes it or the bounded timeout expires.
  }

  private func send(_ data: Data) throws {
    guard let session, let expectedPeer else { throw NearbyPairingError.transportUnavailable }
    try session.send(data, toPeers: [expectedPeer], with: .reliable)
  }

  private func scheduleTimeout() {
    let token = generation
    timeoutTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(NearbyPairingExchange.lifetime)) } catch { return }
      guard let self, self.generation == token else { return }
      self.finishAttempt()
    }
  }

  private func clearSession() {
    sessionDelegate?.invalidate()
    session?.delegate = nil
    session?.disconnect()
    session = nil
    sessionDelegate = nil
    expectedPeer = nil
    exchange = nil
    approvedPayload = nil
    pendingRequest = nil
  }

  private func finishAttempt() {
    generation = UUID()
    timeoutTask?.cancel()
    timeoutTask = nil
    clearSession()
    state = advertiser == nil ? .idle : .advertising
  }

  private func fail() {
    finishAttempt()
    errorMessage = "Nearby pairing could not complete. Try again."
    state = .failed
  }
}

struct NearbyInvitation: Codable {
  let version: Int
  let requestID: UUID
}

extension NearbyPairingHost: MCNearbyServiceAdvertiserDelegate {
  nonisolated public func advertiser(
    _ advertiser: MCNearbyServiceAdvertiser,
    didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
    invitationHandler: @escaping (Bool, MCSession?) -> Void
  ) {
    guard context?.count ?? 0 <= 256, let token = callbackAdmission.admit(advertiser) else {
      invitationHandler(false, nil)
      return
    }
    let admission = callbackAdmission
    let response = NearbyInvitationResponse(invitationHandler)
    Task { @MainActor [weak self] in
      defer { admission.release(token) }
      guard let self, self.advertiser === advertiser else {
        response.complete(false, session: nil)
        return
      }
      self.accept(peerID, context: context) { accepted, session in
        response.complete(accepted, session: session)
      }
    }
  }

  nonisolated public func advertiser(
    _ advertiser: MCNearbyServiceAdvertiser,
    didNotStartAdvertisingPeer error: Error
  ) {
    guard let token = callbackAdmission.admit(advertiser) else { return }
    let admission = callbackAdmission
    Task { @MainActor [weak self] in
      defer { admission.release(token) }
      guard let self, self.advertiser === advertiser else { return }
      self.fail()
    }
  }
}

/// MPC's Objective-C invitation callback lacks Sendable annotations. This narrow
/// bridge owns it once and protects consumption with a lock; completion occurs
/// only on MainActor, never concurrently or twice. No peer/session is stored here.
private final class NearbyInvitationResponse: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: ((Bool, MCSession?) -> Void)?

  init(_ handler: @escaping (Bool, MCSession?) -> Void) { self.handler = handler }

  @MainActor func complete(_ accepted: Bool, session: MCSession?) {
    lock.lock()
    let callback = handler
    handler = nil
    lock.unlock()
    callback?(accepted, session)
  }
}
