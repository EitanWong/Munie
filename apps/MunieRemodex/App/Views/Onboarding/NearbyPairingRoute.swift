import Foundation

/// Keeps a post-onboarding pairing screen alive while the adopted service
/// publishes intermediate socket/trust state. Only its own committed handoff
/// may close it; a previous screen cannot finish a newer pairing route.
struct NearbyPairingRoute {
  private(set) var id = UUID()
  private(set) var isPresented = false
  private(set) var targetMacDeviceID: String?
  private(set) var targetSessionID: String?
  private(set) var preservesExistingConnectionOnFailure = false

  mutating func present() {
    guard !isPresented else { return }
    id = UUID()
    isPresented = true
  }

  mutating func hold(
    _ requestID: UUID, targetMacDeviceID: String? = nil, targetSessionID: String? = nil
  ) -> Bool {
    guard id == requestID else { return false }
    isPresented = true
    self.targetMacDeviceID = targetMacDeviceID
    self.targetSessionID = targetSessionID
    preservesExistingConnectionOnFailure = false
    return true
  }

  @discardableResult
  mutating func finish(_ requestID: UUID) -> Bool {
    guard isPresented, id == requestID else { return false }
    isPresented = false
    targetMacDeviceID = nil
    targetSessionID = nil
    preservesExistingConnectionOnFailure = false
    id = UUID()
    return true
  }

  mutating func preserveExistingConnectionAfterFailure(_ requestID: UUID) {
    guard isPresented, id == requestID else { return }
    preservesExistingConnectionOnFailure = true
  }

  func matchesConnectedTarget(
    _ requestID: UUID, currentMacDeviceID: String?, relaySessionID: String?,
    isConnected: Bool, isInitialized: Bool
  ) -> Bool {
    guard isPresented, id == requestID, isConnected, isInitialized,
      let targetMacDeviceID, let targetSessionID
    else { return false }
    return currentMacDeviceID == targetMacDeviceID && relaySessionID == targetSessionID
  }

  func shouldPresent(
    isConnected: Bool,
    hasReconnectCandidate: Bool,
    isManualPairing: Bool,
    isRecovering: Bool,
    hasDismissedAutomaticPairing: Bool
  ) -> Bool {
    if isPresented { return true }
    guard !isConnected else { return false }
    if isManualPairing { return true }
    guard !isRecovering else { return false }
    return !hasReconnectCandidate && !hasDismissedAutomaticPairing
  }
}
