import Foundation
import Testing

@testable import MunieHostTransport

@Test func strictFramingWaitsForCompleteBody() throws {
  let header =
    "POST /v1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\nAuthorization: Bearer secret\r\n\r\n"
  #expect(try HostHTTPRequest.decode(Data((header + "{").utf8)) == nil)
  let result = try #require(try HostHTTPRequest.decode(Data((header + "{}").utf8)))
  #expect(result.credential == "secret")
  #expect(result.body == Data("{}".utf8))
}

@Test(arguments: [
  "Content-Length: 2\r\ncontent-length: 2", "Content-Length: 2\r\nTransfer-Encoding: chunked",
  "Content-Length: +2", "Content-Length: 65537",
  "Content-Length: 2\r\nOrigin: https://attacker.example",
  "Content-Length: 2\r\n folded: value", "Content-Length: 2\r\nExpect: 100-continue",
])
func ambiguousHTTPIsRejected(headers: String) {
  let request =
    "POST /v1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n\(headers)\r\n\r\n{}"
  #expect(throws: HostHTTPError.self) { try HostHTTPRequest.decode(Data(request.utf8)) }
}

@Test func pipelinedAndUnboundedRequestsAreRejected() {
  let request =
    "POST /v1 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}GET /v1 HTTP/1.1"
  #expect(throws: HostHTTPError.self) { try HostHTTPRequest.decode(Data(request.utf8)) }
  #expect(throws: HostHTTPError.self) {
    try HostHTTPRequest.decode(Data(repeating: 65, count: 8193))
  }
}
