import Foundation
import MaiCore

extension MemoryChat {
  /// Projects a PocketMai conversation into the shape MaiCore's memory tools
  /// read. Errors are dropped, and attached documents are kept apart from what
  /// was actually said.
  init(_ conversation: Conversation, scope: String = "") {
    self.init(
      id: conversation.id,
      title: conversation.title,
      scope: scope,
      updatedAt: conversation.updatedAt,
      entries: conversation.messages.compactMap { message in
        guard message.role != .error else { return nil }
        let text = MessageContentFilter.promptSafeText(from: message.text)
        guard !text.isEmpty else { return nil }
        return Entry(role: message.role.displayName, text: text, date: message.createdAt)
      },
      documents: conversation.messages.flatMap(\.attachments)
        .filter { $0.kind == .textFile }
        .compactMap { attachment in
          attachment.text.map { Document(name: attachment.displayName, text: $0) }
        })
  }
}

/// Memory tools that let the assistant use other chats on this device as a
/// source of information. The tools themselves live in MaiCore and are shared
/// with pmai; this decides which chats they may reach, from the
/// ConversationSearchScope picked in the Memory tool settings.
@MainActor
enum ConversationSearchTool {
  static let toolNames = MaiMemoryTools.toolNames
  static let definitions = MaiMemoryTools.definitions

  static func execute(
    name: String,
    arguments: [String: AgentToolArgumentValue],
    conversation: Conversation,
    store: AppStore
  ) -> String {
    let scope = store.settings.toolSettings.conversationSearchScope
    guard scope != .none else {
      return "Error: access to other chats is disabled in the Memory tool settings."
    }
    return MaiMemoryTools.execute(
      name: name,
      arguments: arguments,
      chats: reachableChats(scope: scope, current: conversation, store: store))
  }

  /// Other chats visible to the tools: never the current chat itself, and only
  /// the current chat's folder unless the scope opens all folders.
  private static func reachableChats(
    scope: ConversationSearchScope,
    current: Conversation,
    store: AppStore
  ) -> [MemoryChat] {
    let folderNames = Dictionary(
      uniqueKeysWithValues: store.conversationFolders.map { ($0.id, $0.displayName) })
    return
      store.conversations
      .filter { $0.id != current.id }
      .filter { scope == .allFolders || $0.folderID == current.folderID }
      .sorted { $0.updatedAt > $1.updatedAt }
      .map { MemoryChat($0, scope: folderNames[$0.folderID] ?? $0.folderID) }
  }
}
