import Foundation
import Testing

@testable import MaiCore
@testable import MaiMCP
@testable import MaiStandardTools
@testable import MaiVisionOCR

@Test("Bundled integrations install independently of MaiCore built-ins")
func installsBundledIntegrationPlugins() async throws {
  let registry = PluginRegistry()
  try await registry.install(MaiMCPPlugin())
  try await registry.install(MaiStandardToolsPlugin())
  try await registry.install(MaiVisionOCRPlugin())

  #expect(
    await registry.installedPlugins().map(\.manifest.id) == [
      "org.mai.mcp", "org.mai.standard-tools", "org.mai.vision-ocr",
    ])
  let tools = try await registry.makeTools(
    kind: MaiStandardToolsPlugin.factoryKind,
    context: PluginFactoryContext(
      id: "standard", options: ["tools": .array([.string(MaiCalculatorTool.name)])]))
  let calculator = try #require(tools.first)
  let output = try await calculator.call(
    arguments: .object(["expression": .string("(2 + 3) * 4")]),
    context: ToolExecutionContext(
      run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
      modelTurn: 1))
  #expect(output.text == "20")
  let ocr = try await registry.makeOCRProvider(
    kind: "vision",
    context: PluginFactoryContext(id: "vision"))
  #expect(ocr.descriptor.id == "vision")
  let mcp = try await registry.makeMCPToolSource(
    kind: "streamable-http",
    configuration: ConfiguredMCPServer(
      id: "fixture",
      url: URL(string: "https://example.com/mcp")!),
    environment: [:])
  #expect(mcp is MCPClient)
}

@Test("Tool factories describe logical groups and their configuration")
func toolFactoryGroups() async throws {
  let registry = PluginRegistry()
  try await registry.install(MaiStandardToolsPlugin())

  let groups = try await registry.toolGroups(
    kind: MaiStandardToolsPlugin.factoryKind,
    context: PluginFactoryContext(
      id: "standard",
      options: ["webSearchFetchingEnabled": .bool(false)]))
  let github = try #require(groups.first { $0.id == "github" })
  #expect(github.sourceID == "standard")
  #expect(github.toolNames == Set(MaiGitHubTool.toolNames))
  let mastodon = try #require(groups.first { $0.id == "mastodon" })
  #expect(mastodon.options.contains { $0.id == "mastodonAPIKeyEnvironment" })
  #expect(mastodon.options.contains { $0.id == "mastodonWriteEnabled" })
  let web = try #require(groups.first { $0.id == "web" })
  #expect(web.toolNames == [MaiWebSearchTool.name])
}

@Test("Factories without group metadata infer prefix groups")
func inferredToolFactoryGroups() async throws {
  let registry = PluginRegistry()
  try await registry.install(FixturePlugin())
  let groups = try await registry.toolGroups(
    kind: "fixture",
    context: PluginFactoryContext(id: "fixture-source"))

  let group = try #require(groups.first)
  #expect(group.id == "fixture")
  #expect(group.sourceID == "fixture-source")
  #expect(group.toolNames == ["fixture_echo"])
}

@Test("A plugin installs all declared capability factories")
func installsPluginCapabilities() async throws {
  let registry = PluginRegistry()
  try await registry.install(FixturePlugin(), origin: "test")

  let installed = await registry.installedPlugins()
  #expect(installed.map(\.manifest.id) == ["fixture"])
  #expect(installed.first?.origin == "test")

  let provider = try await registry.makeProvider(
    from: ConfiguredProvider(id: "fixture-provider", kind: "fixture"),
    environment: [:])
  #expect(provider.descriptor.id == "fixture-provider")

  let tools = try await registry.makeTools(
    kind: "fixture",
    context: PluginFactoryContext(id: "tools"))
  #expect(tools.map(\.definition.name) == ["fixture_echo"])

  let ocr = try await registry.makeOCRProvider(
    kind: "fixture",
    context: PluginFactoryContext(id: "ocr"))
  #expect(ocr.descriptor.id == "ocr")

  let mcp = try await registry.makeMCPToolSource(
    kind: "fixture",
    configuration: ConfiguredMCPServer(
      id: "mcp",
      url: URL(string: "https://example.com/mcp")!),
    environment: [:])
  #expect(try await mcp.connect().serverID == "mcp")
}

@Test("Plugin installation is atomic when registration fails")
func pluginInstallationRollsBack() async throws {
  let registry = PluginRegistry()
  await #expect(throws: PluginRegistryError.self) {
    try await registry.install(IncompletePlugin())
  }
  #expect(await registry.installedPlugins().isEmpty)
  await #expect(throws: PluginRegistryError.self) {
    _ = try await registry.makeProvider(
      from: ConfiguredProvider(id: "missing", kind: "fixture"), environment: [:])
  }
}

private struct FixturePlugin: MaiPlugin {
  let manifest = PluginManifest(
    id: "fixture",
    displayName: "Fixture",
    version: "1.0.0",
    capabilities: [.chatProvider, .agentTool, .ocrProvider, .mcpToolSource])

  func register(in registry: PluginRegistry) async throws {
    try await registry.register(providerFactory: FixtureProviderFactory(), from: manifest.id)
    try await registry.register(toolFactory: FixtureToolFactory(), from: manifest.id)
    try await registry.register(ocrFactory: FixtureOCRFactory(), from: manifest.id)
    try await registry.register(mcpFactory: FixtureMCPFactory(), from: manifest.id)
  }
}

private struct IncompletePlugin: MaiPlugin {
  let manifest = PluginManifest(
    id: "incomplete",
    displayName: "Incomplete",
    version: "1.0.0",
    capabilities: [.chatProvider])

  func register(in registry: PluginRegistry) async throws {}
}

private struct FixtureProviderFactory: ConfiguredProviderFactory {
  let kind = ConfiguredProviderKind("fixture")

  func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    HelloProvider(id: ProviderID(configuration.id))
  }
}

private struct FixtureToolFactory: ConfiguredToolFactory {
  let kind = "fixture"

  func makeTools(context: PluginFactoryContext) async throws -> [any AgentTool] {
    [
      ClosureTool(
        definition: ToolDefinition(name: "fixture_echo", description: "Fixture"),
        operation: { _, _ in ToolOutput(text: "fixture") })
    ]
  }
}

private struct FixtureOCRFactory: ConfiguredOCRProviderFactory {
  let kind = "fixture"

  func makeOCRProvider(context: PluginFactoryContext) throws -> any OCRProvider {
    FixtureOCR(id: context.id)
  }
}

private struct FixtureOCR: OCRProvider {
  var id: String
  var descriptor: OCRProviderDescriptor { .init(id: id, displayName: "Fixture") }
  func recognize(_ request: OCRRequest) async throws -> OCRResult { .init(markdown: "fixture") }
}

private struct FixtureMCPFactory: ConfiguredMCPToolSourceFactory {
  let kind = "fixture"

  func makeMCPToolSource(
    from configuration: ConfiguredMCPServer,
    environment: [String: String]
  ) throws -> any MCPToolSource {
    FixtureMCP(id: configuration.id)
  }
}

private struct FixtureMCP: MCPToolSource {
  var id: String

  func connect() async throws -> MCPServerCatalog {
    MCPServerCatalog(
      serverID: id,
      serverName: "Fixture",
      protocolVersion: "fixture",
      tools: [],
      resources: [])
  }

  func agentTools() async throws -> [any AgentTool] { [] }
  func close() async {}
}
