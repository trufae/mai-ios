import Foundation
import Testing

@testable import MaiCore

@Test("Configurations save atomically and create their parent directory")
func configurationSaveRoundTrip() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("maicore-config-\(UUID().uuidString)", isDirectory: true)
  let url = root.appendingPathComponent("nested/pmai.json")
  let configuration = MaiConfiguration(
    defaultAgent: "local",
    providers: [
      ConfiguredProvider(
        id: "endpoint",
        kind: .openAICompatible,
        baseURL: URL(string: "http://127.0.0.1:1234/v1"))
    ],
    mcpServers: [
      ConfiguredMCPServer(id: "tools", url: URL(string: "https://example.com/mcp"))
    ],
    agents: [
      AgentDefinition(
        id: "local",
        instructions: "Be concise.",
        systemPrompt: "concise",
        provider: "endpoint",
        model: "local-model")
    ],
    prompts: ConfiguredPrompts(
      compact: "Summarize this conversation:\n\n{{transcript}}",
      system: ["concise": "Be concise."]),
    ui: ConfiguredTerminalUI(
      backgroundLine: "magenta",
      foreground: "bright-white",
      promptForeground: "cyan",
      toolResultForeground: "bright-yellow",
      bold: true,
      toolResultLines: 7))

  try configuration.save(to: url)

  #expect(FileManager.default.fileExists(atPath: url.path))
  #expect(try MaiConfiguration.load(from: url) == configuration)
}

@Test("Configurations without prompt templates keep using built-in defaults")
func configurationPromptDefaults() throws {
  let configuration = try JSONDecoder().decode(
    MaiConfiguration.self,
    from: Data(#"{"version":1}"#.utf8))

  #expect(configuration.prompts == nil)
}

@Test("Compact prompt templates require the transcript placeholder")
func compactPromptRequiresTranscript() {
  let configuration = MaiConfiguration(
    prompts: ConfiguredPrompts(compact: "Summarize the chat."))

  #expect(
    throws: MaiConfigurationError.missingPromptPlaceholder(
      prompt: "compact", placeholder: "{{transcript}}")
  ) {
    try configuration.validate()
  }
}

@Test("Inline agent instructions migrate to associated reusable prompts")
func inlineInstructionsBecomeSystemPrompts() {
  var configuration = MaiConfiguration(
    providers: [ConfiguredProvider(id: "hello", kind: .hello)],
    agents: [
      AgentDefinition(
        id: "main",
        instructions: "Be concise.",
        provider: "hello",
        model: "")
    ])

  let didMigrate = configuration.associateSystemPrompts()
  #expect(didMigrate)
  #expect(configuration.agents[0].systemPrompt == "main")
  #expect(configuration.prompts?.system["main"] == "Be concise.")

  configuration.prompts?.system["main"] = "Be extremely concise."
  let didRefresh = configuration.associateSystemPrompts()
  #expect(didRefresh)
  #expect(configuration.agents[0].instructions == "Be extremely concise.")
}
