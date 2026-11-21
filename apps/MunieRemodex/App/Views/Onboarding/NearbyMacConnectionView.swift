// Munie modification: explicit local discovery and two-device confirmation; no terminal setup.
import MunieNearby
import SwiftUI

struct NearbyMacConnectionView: View {
  let allowsDiscovery: Bool
  let isSelected: Bool
  let onPairing: (CodexPairingQRPayload) async -> Bool
  let onConnected: () -> Void
  let onCancelConnection: () async -> Void
  var onBack: (() -> Void)? = nil
  var onScanQRCode: (() -> Void)? = nil
  var onPairWithCode: (() -> Void)? = nil
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var client = NearbyPairingClient()
  @StateObject private var connection = NearbyConnectionAttempt()
  @State private var localError = false
  @State private var active = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let onBack {
          Button(String(localized: "Back"), systemImage: "chevron.left", action: onBack)
            .disabled(!canLeavePairing)
            .accessibilityIdentifier("munie.nearby.back")
        }
        Image(systemName: "laptopcomputer.and.iphone")
          .font(.system(size: 48))
          .foregroundStyle(.white)
          .accessibilityHidden(true)
        Text(String(localized: "Connect to Your Mac"))
          .font(AppFont.system(size: 28, weight: .bold))
          .accessibilityIdentifier("munie.nearby.title")
        Text(
          String(
            localized:
              "Open Munie on your Mac, sign in to Codex, and choose a project. Keep both apps open nearby."
          )
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        connectionContent

        if onScanQRCode != nil || onPairWithCode != nil {
          Menu(String(localized: "Advanced Pairing")) {
            if let onScanQRCode {
              Button(
                String(localized: "Scan QR Code"), systemImage: "qrcode.viewfinder",
                action: onScanQRCode)
            }
            if let onPairWithCode {
              Button(
                String(localized: "Pair with Code"), systemImage: "keyboard", action: onPairWithCode
              )
            }
          }
          .disabled(!canLeavePairing)
          .accessibilityIdentifier("munie.nearby.advanced")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(28)
    }
    .onAppear {
      active = isSelected
      beginDiscoveryIfAllowed()
    }
    .onDisappear {
      active = false
      client.stop()
      connection.cancel()
    }
    .onChange(of: isSelected) { _, selected in
      active = selected
      if selected {
        beginDiscoveryIfAllowed()
      } else {
        client.stop()
        connection.cancel()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background {
        client.stop()
        connection.cancel()
      } else if phase == .active, active {
        beginDiscoveryIfAllowed()
      }
    }
    .onChange(of: connection.phase) { _, phase in
      if phase == .idle { beginDiscoveryIfAllowed() }
    }
    .onChange(of: client.receivedPayload) { _, data in
      guard let data, active, isSelected, scenePhase == .active, connection.phase == .idle else {
        return
      }
      do {
        let payload = try NearbyPairingPayloadValidator.decode(data)
        client.stop()
        connection.start(
          expiresAt: Date(timeIntervalSince1970: Double(payload.expiresAt) / 1_000),
          connect: { await onPairing(payload) },
          disconnect: onCancelConnection,
          onConnected: onConnected)
      } catch {
        client.stop()
        localError = true
      }
    }
  }

  @ViewBuilder
  private var connectionContent: some View {
    if connection.phase == .connecting || connection.phase == .cancelling {
      ProgressView(String(localized: "Connecting to Your Mac…"))
      if connection.phase == .connecting {
        Button(String(localized: "Cancel"), role: .cancel) { connection.cancel() }
          .accessibilityIdentifier("munie.nearby.cancel")
      }
    } else if connection.phase == .failed {
      Label(String(localized: "Could Not Connect"), systemImage: "exclamationmark.triangle")
        .font(.headline)
      Text(String(localized: "Keep Munie open on both devices and try pairing again."))
        .foregroundStyle(.secondary)
      retryButton
    } else if localError || client.state == .failed {
      Label(String(localized: "Could Not Pair"), systemImage: "exclamationmark.triangle")
        .font(.headline)
      Text(
        String(
          localized:
            "Check that both apps have Local Network access, then try again. No device was trusted."
        )
      )
      .foregroundStyle(.secondary)
      retryButton
    } else if let code = client.verificationCode {
      Text(String(localized: "Compare the Code"))
        .font(.headline)
      Text(verbatim: code)
        .font(.system(size: 40, weight: .bold, design: .monospaced))
        .accessibilityLabel(code.map(String.init).joined(separator: " "))
        .accessibilityIdentifier("munie.nearby.verificationCode")
      Text(
        String(
          localized:
            "Check that this exact code appears in Munie on your Mac. Only continue if both codes match."
        )
      )
      .foregroundStyle(.secondary)
      if client.state == .verifying {
        Button(String(localized: "Codes Match")) {
          do { try client.confirmVerificationCode() } catch {
            localError = true
            client.stop()
          }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("munie.nearby.confirm")
      } else {
        ProgressView(String(localized: "Approve this iPhone on your Mac."))
      }
      Button(String(localized: "Cancel"), role: .cancel) {
        client.stop()
        beginDiscoveryIfAllowed()
      }
      .accessibilityIdentifier("munie.nearby.cancel")
    } else if client.state == .connecting {
      ProgressView(String(localized: "Connecting to Your Mac…"))
      Button(String(localized: "Cancel"), role: .cancel) {
        client.stop()
        beginDiscoveryIfAllowed()
      }
      .accessibilityIdentifier("munie.nearby.cancel")
    } else {
      Label(String(localized: "Nearby Macs"), systemImage: "wifi")
        .font(.headline)
      if client.discoveredHosts.isEmpty {
        ProgressView(String(localized: "Looking for Your Mac…"))
          .accessibilityIdentifier("munie.nearby.searching")
      } else {
        ForEach(client.discoveredHosts) { host in
          Button {
            do { try client.requestPairing(with: host) } catch {
              localError = true
              client.stop()
            }
          } label: {
            Label {
              Text(verbatim: host.displayName)
            } icon: {
              Image(systemName: "laptopcomputer")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("munie.nearby.host")
        }
      }
      Text(
        String(
          localized:
            "Allow Local Network access when asked. Nearby discovery only shares device names; pairing requires confirmation on both devices."
        )
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  private func beginDiscoveryIfAllowed() {
    guard allowsDiscovery, active, scenePhase == .active,
      connection.phase == .idle, client.state == .idle
    else { return }
    client.start()
  }

  private var canLeavePairing: Bool {
    (connection.phase == .idle || connection.phase == .failed)
      && (client.state == .idle || client.state == .browsing || client.state == .failed)
  }

  private var retryButton: some View {
    Button(String(localized: "Try Again")) {
      localError = false
      client.stop()
      connection.resetFailure()
      beginDiscoveryIfAllowed()
    }
    .accessibilityIdentifier("munie.nearby.retry")
  }
}
