import Foundation
import Testing

@testable import MunieNativeNetworkProbe

@Suite("Native Codex research reply boundary")
struct CodexReplyTests {
  private let requestID = "70000000-0000-0000-0000-000000000006"
  private let token = "70000000-0000-0000-0000-000000000008"

  private func body() -> [String: Any] {
    [
      "state": "codex-snapshot", "requestID": requestID, "phase": "running",
      "hasUpstream": true, "cancellationRequested": false, "pendingApproval": true,
      "eventKind": "approval", "approvalToken": token, "agentMessageMatched": false,
    ]
  }

  @Test
  func nativeSnapshotKeepsApprovalAndCancellationSeparateFromCompletion() throws {
    let reply = try parseFixtureReply(JSONSerialization.data(withJSONObject: body()))
    #expect(reply["state"] as? String == "codex-snapshot")
    #expect(reply["phase"] as? String == "running")
    #expect(reply["pendingApproval"] as? Bool == true)
    #expect(reply["cancellationRequested"] as? Bool == false)
    #expect(reply["approvalToken"] as? String == token)
    #expect(reply["ordinal"] == nil)
  }

  @Test(arguments: ["command", "cwd", "payload", "rpcID", "deviceID", "error"])
  func unapprovedNativePayloadDoesNotCrossTransportProjection(field: String) throws {
    var value = body()
    value[field] = "private native material"
    #expect(throws: (any Error).self) {
      try parseFixtureReply(JSONSerialization.data(withJSONObject: value))
    }
  }

  @Test(arguments: [
    "hasUpstream", "cancellationRequested", "pendingApproval", "agentMessageMatched",
  ])
  func integersCannotBecomeDomainBooleans(field: String) throws {
    var value = body()
    value[field] = 1
    #expect(throws: (any Error).self) {
      try parseFixtureReply(JSONSerialization.data(withJSONObject: value))
    }
  }

  @Test
  func invalidApprovalCorrelationIsRejected() throws {
    var value = body()
    value["pendingApproval"] = false
    #expect(throws: (any Error).self) {
      try parseFixtureReply(JSONSerialization.data(withJSONObject: value))
    }
    value = body()
    value["approvalToken"] = "wrong"
    #expect(throws: (any Error).self) {
      try parseFixtureReply(JSONSerialization.data(withJSONObject: value))
    }
    value = body()
    value.removeValue(forKey: "eventKind")
    #expect(throws: (any Error).self) {
      try parseFixtureReply(JSONSerialization.data(withJSONObject: value))
    }
  }

  @Test
  func controlBodiesCannotSelectIdentityOrNativeRPC() throws {
    let data = Data(
      """
      {"path":"approval","requestID":"\(requestID)","projectID":"unused","payload":"unused",\
      "cancel":false,"approvalToken":"\(token)","decision":"cancel"}
      """.utf8)
    let command = try JSONDecoder().decode(FixtureCommand.self, from: data)
    #expect(
      try fixtureRequestBody(command)
        == ["requestID": requestID, "approvalToken": token, "decision": "cancel"])
    let config = FixtureConfiguration(
      port: 60443, caDERPath: "/fixture/ca.der", identityPKCS12Path: nil, passphrase: nil)
    for path in ["events", "approval", "interrupt", "reconcile"] {
      #expect(try config.endpoint(path: path).path == "/fixture/\(path)")
    }
    for path in ["rpc", "revoke", "claim", "authorizeDevice", "../approval"] {
      #expect(throws: ProbeFailure.self) { try config.endpoint(path: path) }
    }
  }
}
