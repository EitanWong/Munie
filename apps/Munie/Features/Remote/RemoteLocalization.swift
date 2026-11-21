#if os(iOS)
  import Foundation
  import MunieRemote

  /// Product strings live in their own bilingual catalog; remote content remains user data.
  func remoteString(_ key: String) -> String {
    NSLocalizedString(key, tableName: "Remote", bundle: .main, comment: "")
  }

  extension RemotePhase {
    var displayName: String {
      switch self {
      case .accepted: remoteString("Accepted by Mac")
      case .running: remoteString("Running on Mac")
      case .reconciling: remoteString("Checking execution state")
      case .completed: remoteString("Completed")
      case .failed: remoteString("Failed")
      case .cancelled: remoteString("Cancelled by Mac")
      }
    }
  }

  func remoteProgress(_ code: String) -> String {
    switch code {
    case "codex.turn.started": remoteString("Codex started working.")
    case "codex.command.started": remoteString("Codex started a command.")
    case "codex.command.completed": remoteString("A command finished.")
    case "codex.response.writing": remoteString("Codex is writing a response.")
    case "host.notStarted":
      remoteString("The request did not start on the Mac. Review the result before trying again.")
    case "host.result.truncated":
      remoteString(
        "This result exceeds the display limit. Inspect the complete result on your Mac.")
    case "host.reconciling":
      remoteString("The Mac is checking the existing task. It will not send it again.")
    case "host.unavailable": remoteString("The execution service is unavailable. Check the Mac.")
    case "approval.expired": remoteString("This approval expired. Check the latest task state.")
    default: remoteString("Codex reported progress.")
    }
  }
#endif
