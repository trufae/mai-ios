import XCTest

@testable import PocketMai

/// Regression tests for the tool proxy: a native `call_tool` invocation is
/// re-serialized to a `<tool_call>` block and re-parsed by the tool loop, and
/// the parser's wrapped-call unwrapping must not strip the proxy envelope —
/// call-tool's own parameters (name + arguments) are shape-identical to the
/// generic wrapper scaffolding the unwrap heuristic targets.
final class ToolProxyCallParsingTests: XCTestCase {
  private let searchDefinition = ToolDefinition(
    name: "search",
    description: "Search for a query.",
    parameters: [
      ToolParameterDef(
        name: "query",
        type: "string",
        description: "Search query.",
        required: true)
    ])

  @MainActor
  func testNativeCallToolEnvelopeSurvivesRoundTripParsing() {
    let definitions = ToolProxy.definitions
    // Exact block produced for the DeepWiki MCP call that previously failed
    // with "tool 'read_wiki_structure' is not available".
    let block =
      #"<tool_call id="call_00_ckST6CkbeQRTWCb7OUZh2132" api_name="call_tool">{"arguments":{"arguments":{"repoName":"trufae\/mai"},"name":"read_wiki_structure"},"name":"call_tool"}</tool_call>"#

    let calls = AgentTooling.parseCalls(in: block, tools: definitions, mode: .native)
    XCTAssertEqual(calls.count, 1)
    guard let call = calls.first else { return }

    let normalized = AgentTooling.normalized(call: call, tools: definitions)
    XCTAssertEqual(normalized.name, ToolProxy.callName)
    XCTAssertTrue(AgentTooling.containsDefinition(named: normalized.name, in: definitions))
    XCTAssertEqual(normalized.argumentValues["name"]?.stringValue, "read_wiki_structure")
    guard case .object(let nested)? = normalized.argumentValues["arguments"] else {
      XCTFail("call-tool arguments must remain a nested object")
      return
    }
    XCTAssertEqual(nested["repoName"]?.stringValue, "trufae/mai")
  }

  @MainActor
  func testPlaceholderWrapperStillUnwrapsToInnerTool() {
    let block =
      #"<tool_call>{"name":"tool_call","arguments":{"name":"search","arguments":{"query":"radare2"}}}</tool_call>"#

    let calls = AgentTooling.parseCalls(
      in: block, tools: [searchDefinition], mode: .native)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.name, "search")
    XCTAssertEqual(calls.first?.argumentValues["query"]?.stringValue, "radare2")
  }

  @MainActor
  func testUnknownWrapperNameStillUnwrapsToInnerTool() {
    let block =
      #"<tool_call>{"name":"invoke","arguments":{"name":"search","arguments":{"query":"radare2"}}}</tool_call>"#

    let calls = AgentTooling.parseCalls(
      in: block, tools: [searchDefinition], mode: .native)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.name, "search")
    XCTAssertEqual(calls.first?.argumentValues["query"]?.stringValue, "radare2")
  }

  @MainActor
  func testDoubleWrappedKnownToolStillUnwraps() {
    let block =
      #"<tool_call>{"name":"search","arguments":{"name":"search","arguments":{"query":"radare2"}}}</tool_call>"#

    let calls = AgentTooling.parseCalls(
      in: block, tools: [searchDefinition], mode: .native)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.name, "search")
    XCTAssertEqual(calls.first?.argumentValues["query"]?.stringValue, "radare2")
  }

  @MainActor
  func testToolWithNameArgumentKeepsNameAsArgument() {
    let definition = ToolDefinition(
      name: "webxdc_create",
      description: "Create a webxdc app.",
      parameters: [
        ToolParameterDef(
          name: "name",
          type: "string",
          description: "App name.",
          required: true)
      ])
    let block = #"<tool_call>{"name":"webxdc_create","arguments":{"name":"myapp"}}</tool_call>"#

    let calls = AgentTooling.parseCalls(in: block, tools: [definition], mode: .native)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.name, "webxdc_create")
    XCTAssertEqual(calls.first?.argumentValues["name"]?.stringValue, "myapp")
  }
}
