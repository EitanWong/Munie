import Foundation

public struct NearbyHost: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let displayName: String
}

public struct NearbyPairingRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let deviceName: String
  public let verificationCode: String
  public let phoneConfirmed: Bool
}

public enum NearbyPairingHostState: Equatable, Sendable {
  case idle, advertising, awaitingConfirmation, connected, failed
}

public enum NearbyPairingClientState: Equatable, Sendable {
  case idle, browsing, connecting, verifying, awaitingApproval, received, failed
}
