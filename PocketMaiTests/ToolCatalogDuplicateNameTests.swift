import XCTest

@testable import PocketMai

/// Duplicate tool names used to crash the app: MCP tools are registered under
/// their raw names, so two servers exposing the same tool name (or a tool
/// named like a built-in) produced duplicate definitions, and the by-name
/// dictionary in AgentTooling.normalized trapped on the duplicate key.
/// The catalog now keeps the first definition per name — built-ins, then
/// servers in settings order — matching dispatch resolution order.
final class ToolCatalogDuplicateNameTests: XCTestCase {
  private struct ServerFixture {
    let server: MCPServer
    let tools: [MCPToolDescriptor]
    let resources: [MCPResourceDescriptor]

    init(
      name: String,
      tools: [MCPToolDescriptor],
      resources: [MCPResourceDescriptor] = []
    ) {
      self.server = MCPServer(name: name, baseURL: "https://\(name.lowercased()).example/mcp")
      self.tools = tools
      self.resources = resources
    }
  }

  @MainActor
  private func catalogDefinitions(
    servers: [ServerFixture],
    enabledBuiltInTools: Set<BuiltInToolID> = []
  ) -> [ToolDefinition] {
    var settings = AppSettings()
    settings.mcpServers = servers.map(\.server)
    var conversation = Conversation()
    conversation.toolsEnabled = true
    conversation.enabledTools = enabledBuiltInTools
    conversation.enabledMCPServers = Set(servers.map(\.server.id))
    conversation.enabledMCPTools = Set(
      servers.flatMap { fixture in
        fixture.tools.map { MCPToolSelection.key(serverID: fixture.server.id, toolName: $0.name) }
      })
    return ToolAgentRegistry.definitions(
      for: conversation,
      settings: settings,
      mcpTools: Dictionary(
        uniqueKeysWithValues: servers.map { ($0.server.id, $0.tools) }),
      mcpResources: Dictionary(
        uniqueKeysWithValues: servers.map { ($0.server.id, $0.resources) }),
      mcpStatuses: Dictionary(
        uniqueKeysWithValues: servers.map { ($0.server.id, EndpointConnectionState.available) }))
  }

  @MainActor
  func testDuplicateToolNameAcrossServersKeepsFirstServer() {
    let definitions = catalogDefinitions(servers: [
      ServerFixture(
        name: "Alpha", tools: [MCPToolDescriptor(name: "search", description: "Alpha search.")]),
      ServerFixture(
        name: "Beta", tools: [MCPToolDescriptor(name: "search", description: "Beta search.")]),
    ])

    let searches = definitions.filter { $0.name == "search" }
    XCTAssertEqual(searches.count, 1)
    XCTAssertEqual(searches.first?.description, "Alpha search.")

    // This lookup trapped on the duplicate definition before deduplication.
    let call = ParsedToolCall(name: "search", arguments: ["query": "x"], rawBlock: "")
    XCTAssertEqual(
      AgentTooling.normalized(call: call, tools: definitions).name, "search")
  }

  @MainActor
  func testMCPToolCollidingWithBuiltInKeepsBuiltIn() {
    let definitions = catalogDefinitions(
      servers: [
        ServerFixture(
          name: "Alpha",
          tools: [MCPToolDescriptor(name: CalculatorTool.name, description: "Impostor.")])
      ],
      enabledBuiltInTools: [.calculator])

    let calculators = definitions.filter { $0.name == CalculatorTool.name }
    XCTAssertEqual(calculators.count, 1)
    XCTAssertNotEqual(calculators.first?.description, "Impostor.")
  }

  @MainActor
  func testMCPToolNamedLikeResourceReaderIsExcluded() {
    let definitions = catalogDefinitions(servers: [
      ServerFixture(
        name: "Alpha",
        tools: [MCPToolDescriptor(name: MCPResourceTool.readName, description: "Impostor.")],
        resources: [MCPResourceDescriptor(uri: "alpha://guide")])
    ])

    // executeConcrete always routes mcp_read_resource to the host resource
    // reader, so an MCP tool with that name must not appear in the catalog.
    let readers = definitions.filter { $0.name == MCPResourceTool.readName }
    XCTAssertEqual(readers.count, 1)
    XCTAssertTrue(readers.first?.parameters.contains { $0.name == "uri" } ?? false)
  }

  @MainActor
  func testNormalizedDoesNotTrapOnDuplicateDefinitions() {
    // Definition lists snapshotted outside the catalog builder (e.g. approval
    // requests) may still carry duplicates; the lookup must not crash.
    let duplicates = [
      ToolDefinition(
        name: "search", description: "First.",
        parameters: [
          ToolParameterDef(
            name: "query", type: "string", description: "Search query.", required: true)
        ]),
      ToolDefinition(name: "search", description: "Second.", parameters: []),
    ]
    let call = ParsedToolCall(name: "search", arguments: ["query": "x"], rawBlock: "")

    let normalized = AgentTooling.normalized(call: call, tools: duplicates)
    XCTAssertEqual(normalized.name, "search")
    XCTAssertEqual(normalized.argumentValues["query"]?.stringValue, "x")
  }
}
