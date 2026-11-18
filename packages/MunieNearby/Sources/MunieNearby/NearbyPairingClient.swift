import Combine
import Foundation
@preconcurrency import MultipeerConnectivity

@MainActor
public final class NearbyPairingClient: NSObject, ObservableObject {
  @Published public private(set) var state: NearbyPairingClientState = .idle
  @Published public private(set) var discoveredHosts: [NearbyHost] = []
  @Published public private(set) var verificationCode: String?
  @Published public private(set) var receivedPayload: Data?
  @Published public private(set) var errorMessage: String?
  private var browser: MCNearbyServiceBrowser?
  private var peers: [UUID: MCPeerID] = [:]
  private var session: MCSession?
  private var sessionDelegate: NearbySessionDelegate?
  private var exchange: NearbyPairingExchange?
  private var expectedPeer: MCPeerID?
  private var generation = UUID()
  private var timeoutTask: Task<Void, Never>?
  private let deviceName: String
  nonisolated private let callbackAdmission = NearbyCallbackAdmission()

  public init(deviceName: String = "iPhone") {
    self.deviceName = NearbyPairingExchange.validName(deviceName) ? deviceName : "iPhone"
    super.init()
  }

  public func start() {
    stop()
    let browser = MCNearbyServiceBrowser(
      peer: MCPeerID(displayName: deviceName), serviceType: NearbyPairingHost.serviceType)
    self.browser = browser
    callbackAdmission.activate(browser)
    browser.delegate = self
    browser.startBrowsingForPeers()
    state = .browsing
  }

  public func stop() {
    callbackAdmission.invalidate()
    generation = UUID()
    timeoutTask?.cancel()
    timeoutTask = nil
    browser?.delegate = nil
    browser?.stopBrowsingForPeers()
    browser = nil
    sessionDelegate?.invalidate()
    session?.delegate = nil
    session?.disconnect()
    session = nil
    sessionDelegate = nil
    exchange = nil
    expectedPeer = nil
    peers = [:]
    discoveredHosts = []
    verificationCode = nil
    receivedPayload = nil
    errorMessage = nil
    state = .idle
  }

  public func requestPairing(with host: NearbyHost) throws {
    guard state == .browsing, let browser, let peer = peers[host.id] else {
      throw NearbyPairingError.invalidState
    }
    let requestID = UUID()
    let exchange = try NearbyPairingExchange(role: .client, requestID: requestID, name: deviceName)
    let session = MCSession(
      peer: browser.myPeerID, securityIdentity: nil, encryptionPreference: .required)
    generation = UUID()
    let delegate = NearbySessionDelegate(generation: generation, expectedPeer: peer) {
      [weak self] token, event in
      self?.receive(token, event)
    }
    self.exchange = exchange
    self.session = session
    sessionDelegate = delegate
    session.delegate = delegate
    expectedPeer = peer
    verificationCode = nil
    receivedPayload = nil
    errorMessage = nil
    state = .connecting
    let context = try JSONEncoder().encode(NearbyInvitation(version: 1, requestID: requestID))
    browser.invitePeer(peer, to: session, withContext: context, timeout: 30)
    browser.stopBrowsingForPeers()
    let token = generation
    timeoutTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(NearbyPairingExchange.lifetime)) } catch { return }
      guard let self, self.generation == token else { return }
      self.fail()
    }
  }

  public func confirmVerificationCode() throws {
    guard state == .verifying, var exchange else { throw NearbyPairingError.invalidState }
    guard let message = try exchange.confirm() else { throw NearbyPairingError.invalidState }
    try send(message)
    self.exchange = exchange
    state = .awaitingApproval
  }

  private func receive(_ token: UUID, _ event: NearbySessionDelegate.Event) {
    guard token == generation, expectedPeer != nil, session != nil else { return }
    do {
      switch event {
      case .state(let value):
        if value == MCSessionState.connected.rawValue {
          guard let exchange else { throw NearbyPairingError.invalidState }
          try send(exchange.commitment())
        } else if value == MCSessionState.notConnected.rawValue, state != .received {
          fail()
        }
      case .data(let data):
        guard var exchange else {
          throw NearbyPairingError.invalidMessage
        }
        if state == .awaitingApproval {
          let payload = try exchange.openPayload(data)
          self.exchange = exchange
          receivedPayload = payload
          state = .received
          timeoutTask?.cancel()
          timeoutTask = nil
          session?.disconnect()
        } else {
          if let response = try exchange.receiveHandshake(data) { try send(response) }
          self.exchange = exchange
          if let code = exchange.verificationCode {
            verificationCode = code
            state = .verifying
          }
        }
      case .unsupportedTransfer:
        throw NearbyPairingError.invalidMessage
      }
    } catch { fail() }
  }

  private func send(_ data: Data) throws {
    guard let session, let expectedPeer else { throw NearbyPairingError.transportUnavailable }
    try session.send(data, toPeers: [expectedPeer], with: .reliable)
  }

  private func found(_ peer: MCPeerID, info: [String: String]?) {
    guard state == .browsing, info == ["v": "1"], peers.count < 16,
      NearbyPairingExchange.validName(peer.displayName),
      !peers.values.contains(peer)
    else { return }
    let id = UUID()
    peers[id] = peer
    discoveredHosts.append(NearbyHost(id: id, displayName: peer.displayName))
    discoveredHosts.sort {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
  }

  private func lost(_ peer: MCPeerID) {
    for (id, saved) in peers where saved == peer {
      peers[id] = nil
      discoveredHosts.removeAll { $0.id == id }
    }
  }

  private func fail() {
    stop()
    state = .failed
    errorMessage = "Nearby pairing could not complete. Try again."
  }
}

extension NearbyPairingClient: MCNearbyServiceBrowserDelegate {
  nonisolated public func browser(
    _ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
    withDiscoveryInfo info: [String: String]?
  ) {
    guard info == ["v": "1"], NearbyPairingExchange.validName(peerID.displayName),
      let token = callbackAdmission.admit(browser)
    else { return }
    let admission = callbackAdmission
    Task { @MainActor [weak self] in
      defer { admission.release(token) }
      guard let self, self.browser === browser else { return }
      self.found(peerID, info: info)
    }
  }

  nonisolated public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    guard let token = callbackAdmission.admit(browser) else { return }
    let admission = callbackAdmission
    Task { @MainActor [weak self] in
      defer { admission.release(token) }
      guard let self, self.browser === browser else { return }
      self.lost(peerID)
    }
  }

  nonisolated public func browser(
    _ browser: MCNearbyServiceBrowser,
    didNotStartBrowsingForPeers error: Error
  ) {
    guard let token = callbackAdmission.admit(browser) else { return }
    let admission = callbackAdmission
    Task { @MainActor [weak self] in
      defer { admission.release(token) }
      guard let self, self.browser === browser else { return }
      self.fail()
    }
  }
}
