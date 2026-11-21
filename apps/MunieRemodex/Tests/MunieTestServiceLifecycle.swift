import Foundation

@testable import MunieRemodex

/// Finish owned asynchronous work before the next XCTest fixture installs its transport.
@MainActor
enum MunieTestServiceLifecycle {
  static func finish(_ services: [CodexService]) async {
    for service in services {
      await service.disconnect()
      service.stopGPTLoginSync()
      service.requestTransportOverride = nil
    }
    // Let cancelled fixture-owned tasks observe cancellation on the main actor.
    await Task.yield()
  }
}
