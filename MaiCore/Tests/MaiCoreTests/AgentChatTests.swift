import Foundation
import Testing

@testable import MaiCore

private let chatAgent = AgentDefinition(
  id: "local",
  instructions: "Be concise.",
  provider: "endpoint",
  model: "model-a")

@Test("Agent chats retain one primary agent and reset to its instructions")
func agentChatPrimaryAgent() {
  var chat = AgentChat(title: "Work", primaryAgent: chatAgent)
  #expect(chat.messages.count == 1)
  #expect(chat.messages.first?.role == .system)
  #expect(chat.messages.first?.text == "Be concise.")

  var replacement = chatAgent
  replacement.id = "reviewer"
  replacement.instructions = "Review carefully."
  chat.messages.append(.user("old context"))
  chat.assignPrimaryAgent(replacement)

  #expect(chat.primaryAgent.id == "reviewer")
  #expect(chat.messages.count == 1)
  #expect(chat.messages.first?.role == .system)
  #expect(chat.messages.first?.text == "Review carefully.")
}

@Test("Chat workspaces switch, update, remove, and persist chats")
func agentChatWorkspaceRoundTrip() throws {
  let first = AgentChat(title: "First", primaryAgent: chatAgent)
  let second = AgentChat(title: "Second", primaryAgent: chatAgent)
  var workspace = AgentChatWorkspace(chats: [first, second], selectedChatID: first.id)

  let selected = workspace.selectChat(id: second.id)
  #expect(selected)
  #expect(workspace.selectedChat?.title == "Second")
  var changed = second
  changed.title = "Renamed"
  workspace.upsert(changed)
  #expect(workspace.selectedChat?.title == "Renamed")
  #expect(workspace.removeChat(id: second.id) == changed)
  #expect(workspace.selectedChatID == first.id)

  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("maicore-chats-\(UUID().uuidString)/chats.json")
  try workspace.save(to: url)
  #expect(try AgentChatWorkspace.load(from: url) == workspace)
}
