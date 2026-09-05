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
        provider: "endpoint",
        model: "local-model")
    ],
    ui: ConfiguredTerminalUI(
      backgroundLine: "magenta",
      foreground: "bright-white",
      promptForeground: "cyan",
      bold: true,
      toolResultLines: 7))

  try configuration.save(to: url)

  #expect(FileManager.default.fileExists(atPath: url.path))
  #expect(try MaiConfiguration.load(from: url) == configuration)
}
