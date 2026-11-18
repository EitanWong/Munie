import Foundation

/// Upstream compatibility prompts can contain developer shell instructions.
/// The app uses only their target discriminator, never their display text.
struct BridgeUpdatePresentation {
  enum Target { case macApp, iPhoneApp }
  let target: Target

  init(command: String?) { target = command == nil ? .iPhoneApp : .macApp }

  var title: String {
    switch target {
    case .macApp: String(localized: "Update Munie on Your Mac")
    case .iPhoneApp: String(localized: "Update Munie on This iPhone")
    }
  }

  var message: String {
    String(localized: "This operation requires compatible Munie versions on your Mac and iPhone.")
  }

  var guidance: String {
    switch target {
    case .macApp:
      String(
        localized:
          "Install compatible Munie builds on both devices. After updating the Mac app, open it and reconnect from this iPhone."
      )
    case .iPhoneApp:
      String(
        localized:
          "Install compatible Munie builds on both devices. After updating this iPhone app, open it and reconnect to your Mac."
      )
    }
  }
}
