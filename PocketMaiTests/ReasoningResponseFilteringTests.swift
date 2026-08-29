import XCTest

@testable import PocketMai

final class ReasoningResponseFilteringTests: XCTestCase {
  func testRemovingReasoningPreservesToolCallEnvelopeExactly() {
    let toolCall = """
      <tool_call name="search">
      <arg name="query">visible request</arg>
      </tool_call>
      """
    let response = "<think>\nI might call a different tool here.\n</think>\n\n\(toolCall)"

    XCTAssertEqual(
      MessageContentFilter.removingReasoningSections(from: response),
      "\n\n\(toolCall)")
  }

  @MainActor
  func testToolParserDoesNotExecuteCallInsideReasoning() {
    let definition = ToolDefinition(
      name: "search",
      description: "Search for a query.",
      parameters: [
        ToolParameterDef(
          name: "query",
          type: "string",
          description: "Search query.",
          required: true)
      ])
    let response = """
      <think>
      TOOL_CALL
      tool: search
      query: hidden request
      END_TOOL_CALL
      </think>

      TOOL_CALL
      tool: search
      query: visible request
      END_TOOL_CALL
      """
    let actionable = MessageContentFilter.removingReasoningSections(from: response)

    let calls = ToolAgentRegistry.parseCalls(
      in: actionable,
      definitions: [definition],
      mode: .text)

    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.argumentValues["query"]?.stringValue, "visible request")
  }

  func testSpuriousToolCallFilterIgnoresMarkersInsideReasoning() {
    let response = """
      <think>
      TOOL_CALL
      tool: search
      query: internal example
      END_TOOL_CALL
      </think>

      Here is the final answer.
      """

    XCTAssertEqual(AppStore.strippedSpuriousToolCallText(response), response)
  }
}
