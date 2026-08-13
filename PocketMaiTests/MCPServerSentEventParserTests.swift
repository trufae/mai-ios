import XCTest

@testable import PocketMai

final class MCPServerSentEventParserTests: XCTestCase {
  func testParsesMultilineEvent() throws {
    var parser = MCPServerSentEventParser()

    XCTAssertNil(try parser.consume(line: "id: cursor-7"))
    XCTAssertNil(try parser.consume(line: "event: message"))
    XCTAssertNil(try parser.consume(line: "data: {\"jsonrpc\":\"2.0\","))
    XCTAssertNil(try parser.consume(line: "data: \"id\":7,\"result\":{}}"))

    XCTAssertEqual(
      try parser.consume(line: ""),
      MCPServerSentEvent(
        event: "message",
        data: "{\"jsonrpc\":\"2.0\",\n\"id\":7,\"result\":{}}",
        id: "cursor-7"))
  }

  func testIgnoresCommentsAndDispatchesFinalEventAtEOF() throws {
    var parser = MCPServerSentEventParser()

    XCTAssertNil(try parser.consume(line: ": keepalive"))
    XCTAssertNil(
      try parser.consume(line: "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}"))

    XCTAssertEqual(
      try parser.finish(),
      MCPServerSentEvent(
        event: nil,
        data: "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}",
        id: nil))
  }

  func testRecognizesLegacyEndpointEvent() throws {
    var parser = MCPServerSentEventParser()
    _ = try parser.consume(line: "event: endpoint")
    _ = try parser.consume(line: "data: /message?sessionId=abc")

    XCTAssertEqual(try parser.finish()?.isLegacyEndpointEvent, true)
  }

  func testParsesPollingCursorAndRetryDelay() throws {
    var parser = MCPServerSentEventParser()
    _ = try parser.consume(line: "id: stream-42")
    _ = try parser.consume(line: "retry: 250")
    _ = try parser.consume(line: "data:")

    XCTAssertEqual(
      try parser.consume(line: ""),
      MCPServerSentEvent(
        event: nil,
        data: "",
        id: "stream-42",
        retryMilliseconds: 250))
  }
}
