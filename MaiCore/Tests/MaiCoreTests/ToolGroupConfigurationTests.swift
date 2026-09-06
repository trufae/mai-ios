import Foundation
import Testing

@testable import MaiCore

@Test("Agent tool-group selections survive configuration persistence")
func agentToolGroupsRoundTrip() throws {
  let configuration = MaiConfiguration(
    defaultAgent: "main",
    providers: [ConfiguredProvider(id: "hello", kind: .hello)],
    agents: [
      AgentDefinition(
        id: "main",
        instructions: "",
        provider: "hello",
        model: "",
        toolNames: ["github_pr", "github_issue"],
        toolGroupNames: ["github"])
    ])
  let data = try configuration.encoded()
  let decoded = try JSONDecoder().decode(MaiConfiguration.self, from: data)

  #expect(decoded.agents[0].toolGroupNames == ["github"])
}

@Test("Older agents decode with no explicit tool groups")
func legacyAgentToolGroups() throws {
  let data = Data(
    """
    {
      "id": "main",
      "instructions": "",
      "provider": "hello",
      "model": "",
      "toolNames": ["weather"]
    }
    """.utf8)
  let agent = try JSONDecoder().decode(AgentDefinition.self, from: data)

  #expect(agent.toolGroupNames.isEmpty)
  #expect(agent.toolNames == ["weather"])
  #expect(agent.systemPrompt == nil)
}
