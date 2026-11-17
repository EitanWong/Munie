import Foundation
import Testing

@testable import MunieNativeNetworkProbe

@Suite("Native ledger reply boundary")
struct LedgerReplyTests {
  private let requestID = "70000000-0000-0000-0000-000000000004"

  @Test(arguments: [
    "accepted", "dispatching", "running", "reconciling", "completed", "failed", "cancelled",
  ])
  func ledgerStatesRemainDistinctFromFixtureOrdinals(phase: String) throws {
    let reply = try parseFixtureReply(
      Data(
        "{\"state\":\"ledger-snapshot\",\"requestID\":\"\(requestID)\",\"phase\":\"\(phase)\"}".utf8
      ))
    #expect(reply["state"] as? String == "ledger-snapshot")
    #expect(reply["requestID"] as? String == requestID)
    #expect(reply["phase"] as? String == phase)
    #expect(reply["ordinal"] == nil)
  }

  @Test(arguments: [
    #"{"state":"ledger-snapshot","requestID":"bad-id","phase":"accepted"}"#,
    #"{"state":"ledger-snapshot","requestID":true,"phase":"accepted"}"#,
    #"{"state":"ledger-snapshot","requestID":"70000000-0000-0000-0000-000000000004","phase":"invented"}"#,
    #"{"state":"ledger-snapshot","requestID":"70000000-0000-0000-0000-000000000004","phase":"accepted","ordinal":1}"#,
    #"{"state":"ledger-snapshot","requestID":"70000000-0000-0000-0000-000000000004","phase":"accepted","phase":"completed"}"#,
    #"{"state":"ledger-snapshot","requestID":"70000000-0000-0000-0000-000000000004","phase":"accepted","error":"unauthorized"}"#,
  ])
  func invalidOrAmbiguousLedgerRepliesAreRejected(json: String) {
    #expect(throws: (any Error).self) { try parseFixtureReply(Data(json.utf8)) }
  }

  @Test
  func snapshotRouteKeepsExactHTTPSLoopbackBoundary() throws {
    let config = FixtureConfiguration(
      port: 60443, caDERPath: "/fixture/ca.der", identityPKCS12Path: nil, passphrase: nil)
    #expect(
      try config.endpoint(path: "snapshot").absoluteString
        == "https://127.0.0.1:60443/fixture/snapshot")
    #expect(throws: ProbeFailure.self) { try config.endpoint(path: "revoke") }
    #expect(throws: ProbeFailure.self) { try config.endpoint(path: "claim") }
  }
}
