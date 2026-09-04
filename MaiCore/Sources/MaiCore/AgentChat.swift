import Foundation

/// A durable chat transcript associated with one primary agent definition.
/// Providers remain normalized in `MaiConfiguration`; the agent's provider ID
/// resolves the endpoint, credentials, and provider-specific options.
public struct AgentChat: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var primaryAgent: AgentDefinition
  public var messages: [AgentMessage]
  public var pendingContent: [ContentPart]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    primaryAgent: AgentDefinition,
    messages: [AgentMessage]? = nil,
    pendingContent: [ContentPart] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.primaryAgent = primaryAgent
    self.messages = messages ?? Self.initialHistory(for: primaryAgent)
    self.pendingContent = pendingContent
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public mutating func assignPrimaryAgent(
    _ agent: AgentDefinition,
    resettingTranscript: Bool = true
  ) {
    primaryAgent = agent
    if resettingTranscript { messages = Self.initialHistory(for: agent) }
    pendingContent.removeAll()
    touch()
  }

  public mutating func resetTranscript() {
    messages = Self.initialHistory(for: primaryAgent)
    pendingContent.removeAll()
    touch()
  }

  public mutating func touch(at date: Date = Date()) {
    updatedAt = date
  }

  public static func initialHistory(for agent: AgentDefinition) -> [AgentMessage] {
    let instructions = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return instructions.isEmpty ? [] : [.system(instructions)]
  }
}

/// A persistable collection of independent chats and the chat selected by a host.
public struct AgentChatWorkspace: Codable, Equatable, Sendable {
  public var version: Int
  public private(set) var selectedChatID: UUID?
  public private(set) var chats: [AgentChat]

  public init(
    version: Int = 1,
    chats: [AgentChat] = [],
    selectedChatID: UUID? = nil
  ) {
    self.version = version
    self.chats = chats
    self.selectedChatID = selectedChatID.flatMap { id in
      chats.contains(where: { $0.id == id }) ? id : nil
    } ?? chats.first?.id
  }

  public var selectedChat: AgentChat? {
    guard let selectedChatID else { return nil }
    return chats.first { $0.id == selectedChatID }
  }

  @discardableResult
  public mutating func selectChat(id: UUID) -> Bool {
    guard chats.contains(where: { $0.id == id }) else { return false }
    selectedChatID = id
    return true
  }

  public mutating func upsert(_ chat: AgentChat, selecting: Bool = false) {
    if let index = chats.firstIndex(where: { $0.id == chat.id }) {
      chats[index] = chat
    } else {
      chats.append(chat)
    }
    if selecting || selectedChatID == nil { selectedChatID = chat.id }
  }

  @discardableResult
  public mutating func removeChat(id: UUID) -> AgentChat? {
    guard let index = chats.firstIndex(where: { $0.id == id }) else { return nil }
    let removed = chats.remove(at: index)
    if selectedChatID == id {
      selectedChatID = chats.isEmpty ? nil : chats[min(index, chats.count - 1)].id
    }
    return removed
  }

  public static func load(from url: URL) throws -> AgentChatWorkspace {
    try JSONDecoder().decode(AgentChatWorkspace.self, from: Data(contentsOf: url))
  }

  public func save(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}
