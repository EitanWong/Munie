// Munie modification: extracted the upstream viewport geometry policy so it stays testable without GhosttyKit.
import CoreGraphics

enum TerminalViewportPolicy {
  static func isDrawableViewportSize(_ size: CGSize) -> Bool {
    size.width >= 24 && size.height >= 24
  }
}
