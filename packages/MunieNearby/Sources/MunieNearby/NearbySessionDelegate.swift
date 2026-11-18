import Foundation
@preconcurrency import MultipeerConnectivity
import os

/// MPC callbacks are serialized through a bounded mailbox with one MainActor drain.
/// Immutable peer identity is checked before forwarding; no device name acts as identity.
final class NearbySessionDelegate: NSObject, MCSessionDelegate, Sendable {
  enum Event: Sendable {
    case state(value: Int)
    case data(value: Data)
    case unsupportedTransfer

    var byteCount: Int {
      if case .data(let data) = self { data.count } else { 0 }
    }
  }

  private struct Mailbox {
    var events: [Event] = []
    var bytes = 0
    var draining = false
    var closed = false
  }

  let generation: UUID
  private let expectedPeer: MCPeerID
  private let receive: @MainActor @Sendable (UUID, Event) -> Void
  private let mailbox = OSAllocatedUnfairLock(initialState: Mailbox())
  static let maximumQueuedEvents = 8
  static let maximumQueuedBytes = 180_000

  init(
    generation: UUID, expectedPeer: MCPeerID,
    receive: @escaping @MainActor @Sendable (UUID, Event) -> Void
  ) {
    self.generation = generation
    self.expectedPeer = expectedPeer
    self.receive = receive
  }

  func invalidate() {
    mailbox.withLock { state in
      state.closed = true
      state.events.removeAll()
      state.bytes = 0
    }
  }

  func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    enqueue(peerID == expectedPeer ? .state(value: state.rawValue) : .unsupportedTransfer)
  }

  func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
    guard peerID == expectedPeer, data.count <= NearbyPairingExchange.maximumMessageBytes else {
      enqueue(.unsupportedTransfer)
      return
    }
    enqueue(.data(value: data))
  }

  func session(
    _ session: MCSession, didReceive stream: InputStream,
    withName streamName: String, fromPeer peerID: MCPeerID
  ) {
    stream.close()
    enqueue(.unsupportedTransfer)
  }

  func session(
    _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
    fromPeer peerID: MCPeerID, with progress: Progress
  ) {
    progress.cancel()
    enqueue(.unsupportedTransfer)
  }

  func session(
    _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
    fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
  ) {
    if let localURL { try? FileManager.default.removeItem(at: localURL) }
    enqueue(.unsupportedTransfer)
  }

  func enqueue(_ event: Event) {
    let startDrain = mailbox.withLock { state -> Bool in
      guard !state.closed else { return false }
      let isFailure: Bool
      if case .unsupportedTransfer = event { isFailure = true } else { isFailure = false }
      if isFailure || state.events.count >= Self.maximumQueuedEvents
        || event.byteCount > Self.maximumQueuedBytes - state.bytes
      {
        state.events = [.unsupportedTransfer]
        state.bytes = 0
        state.closed = true
      } else {
        state.events.append(event)
        state.bytes += event.byteCount
      }
      guard !state.draining else { return false }
      state.draining = true
      return true
    }
    guard startDrain else { return }
    Task { @MainActor [weak self] in await self?.drain() }
  }

  @MainActor private func drain() async {
    var processed = 0
    while let next = mailbox.withLock({ state -> Event? in
      guard !state.events.isEmpty else {
        state.draining = false
        return nil
      }
      let event = state.events.removeFirst()
      state.bytes -= event.byteCount
      return event
    }) {
      receive(generation, next)
      processed += 1
      if processed == Self.maximumQueuedEvents {
        processed = 0
        await Task.yield()
      }
    }
  }
}
