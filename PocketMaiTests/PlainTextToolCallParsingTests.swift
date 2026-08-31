import XCTest

@testable import PocketMai

/// Regression tests for the plain-text tool protocol: `tool:`, `name:`, and
/// `function:` are the keys that designate the tool, but a tool may also
/// declare a parameter with one of those names (call-tool's `name`,
/// webxdc_create's `name`). The parser used to treat the first such line as
/// the tool name and drop the rest, so those arguments could never be passed.
final class PlainTextToolCallParsingTests: XCTestCase {
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

  private let createDefinition = ToolDefinition(
    name: "webxdc_create",
    description: "Create a webxdc app.",
    parameters: [
      ToolParameterDef(
        name: "name",
        type: "string",
        description: "App name.",
        required: true)
    ])

  @MainActor
  func testTextProxyCallKeepsNameArgument() {
    let block = """
      TOOL_CALL
      tool: call_tool
      name: read_wiki_structure
      arguments: {"repoName":"trufae/mai"}
      END_TOOL_CALL
      """

    let calls = ToolAgentRegistry.parseCalls(
      in: block, definitions: ToolProxy.definitions, mode: .text)
    XCTAssertEqual(calls.count, 1)
    guard let call = calls.first else { return }

    let normalized = ToolAgentRegistry.normalized(call: call, definitions: ToolProxy.definitions)
    XCTAssertEqual(normalized.name, ToolProxy.callName)
    XCTAssertEqual(normalized.argumentValues["name"]?.stringValue, "read_wiki_structure")
    XCTAssertEqual(
      normalized.argumentValues["arguments"]?.stringValue.contains("trufae/mai"), true)
  }

  @MainActor
  func testTextProxyCallWithNameLineBeforeToolLine() {
    let block = """
      TOOL_CALL
      name: read_wiki_structure
      tool: call_tool
      arguments: {"repoName":"trufae/mai"}
      END_TOOL_CALL
      """

    let calls = ToolAgentRegistry.parseCalls(
      in: block, definitions: ToolProxy.definitions, mode: .text)
    XCTAssertEqual(calls.count, 1)
    guard let call = calls.first else { return }

    let normalized = ToolAgentRegistry.normalized(call: call, definitions: ToolProxy.definitions)
    XCTAssertEqual(normalized.name, ToolProxy.callName)
    XCTAssertEqual(normalized.argumentValues["name"]?.stringValue, "read_wiki_structure")
  }

  @MainActor
  func testToolWithRequiredNameParameterReceivesIt() {
    let block = """
      TOOL_CALL
      tool: webxdc_create
      name: myapp
      END_TOOL_CALL
      """

    let calls = ToolAgentRegistry.parseCalls(
      in: block, definitions: [createDefinition], mode: .text)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.name, "webxdc_create")
    XCTAssertEqual(calls.first?.argumentValues["name"]?.stringValue, "myapp")
  }

  @MainActor
  func testNameLineStillDesignatesTheTool() {
    let block = """
      TOOL_CALL
      name: search
      query: radare2
      END_TOOL_CALL
      """

    let calls = ToolAgentRegistry.parseCalls(
      in: block, definitions: [searchDefinition], mode: .text)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.name, "search")
    XCTAssertEqual(calls.first?.argumentValues["query"]?.stringValue, "radare2")
  }

  @MainActor
  func testUndeclaredNameLineIsStillDropped() {
    let block = """
      TOOL_CALL
      tool: search
      name: junk
      query: radare2
      END_TOOL_CALL
      """

    let calls = ToolAgentRegistry.parseCalls(
      in: block, definitions: [searchDefinition], mode: .text)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.name, "search")
    XCTAssertEqual(calls.first?.argumentValues["query"]?.stringValue, "radare2")
    XCTAssertNil(calls.first?.argumentValues["name"])
  }
}
