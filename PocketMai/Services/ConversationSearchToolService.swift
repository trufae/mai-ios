import Foundation

/// Memory tools that let the assistant use other chats on this device as a
/// source of information: list them, search their text and attached documents,
/// and read transcripts or attachments. The reachable chats are limited by the
/// ConversationSearchScope picked in the Memory tool settings.
@MainActor
enum ConversationSearchTool {
  static let listName = "chats_list"
  static let searchName = "chats_search"
  static let readName = "chats_read"
  static let readAttachmentName = "chats_read_attachment"

  static let toolNames: [String] = [listName, searchName, readName, readAttachmentName]

  private static let maxResults = 20
  private static let snippetContext = 90
  private static let maxMessageChars = 1_200
  private static let maxTranscriptChars = 24_000
  private static let maxAttachmentChars = 24_000

  private static let chatParameter = ToolParameterDef(
    name: "chat", type: "string",
    description: "Chat ID (or ID prefix) from chats_list or chats_search, or a title substring.",
    required: true)

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: listName,
      description:
        "List other chats on this device that can be used as an information source, newest first, with their IDs, folders, and attached document names.",
      parameters: [
        ToolParameterDef(
          name: "limit", type: "integer",
          description: "Maximum number of chats, 1-50. Default: 20.",
          required: false)
      ]),
    ToolDefinition(
      name: searchName,
      description:
        "Search text in other chats, including their attached documents, and return matching snippets with chat IDs.",
      parameters: [
        ToolParameterDef(
          name: "query", type: "string",
          description: "Text to search for, case-insensitive.",
          required: true)
      ]),
    ToolDefinition(
      name: readName,
      description: "Read the transcript of one other chat.",
      parameters: [
        chatParameter,
        ToolParameterDef(
          name: "limit", type: "integer",
          description: "Number of most recent messages to include. Default: 30.",
          required: false),
      ]),
    ToolDefinition(
      name: readAttachmentName,
      description: "Read the full text of a document attached to a message of another chat.",
      parameters: [
        chatParameter,
        ToolParameterDef(
          name: "filename", type: "string",
          description: "Attachment filename as shown by chats_list or chats_search.",
          required: true),
      ]),
  ]

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
    let chats = reachableChats(scope: scope, current: conversation, store: store)
    switch name {
    case listName:
      return list(chats: chats, arguments: arguments, store: store)
    case searchName:
      return search(chats: chats, arguments: arguments)
    case readName:
      return read(chats: chats, arguments: arguments)
    case readAttachmentName:
      return readAttachment(chats: chats, arguments: arguments)
    default:
      return "Error: unknown chats tool."
    }
  }

  /// Other chats visible to the tools: never the current chat itself, and only
  /// the current chat's folder unless the scope opens all folders.
  private static func reachableChats(
    scope: ConversationSearchScope,
    current: Conversation,
    store: AppStore
  ) -> [Conversation] {
    store.conversations
      .filter { $0.id != current.id }
      .filter { scope == .allFolders || $0.folderID == current.folderID }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private static func list(
    chats: [Conversation],
    arguments: [String: AgentToolArgumentValue],
    store: AppStore
  ) -> String {
    guard !chats.isEmpty else { return "No other chats are available in this scope." }
    let limit = min(max(arguments["limit"]?.numberValue.map { Int($0) } ?? 20, 1), 50)
    let folderNames = Dictionary(
      uniqueKeysWithValues: store.conversationFolders.map { ($0.id, $0.displayName) })
    let lines = chats.prefix(limit).map { chat -> String in
      var line = "- \(shortID(chat)) [\(folderNames[chat.folderID] ?? chat.folderID)] \(chat.title)"
      line += " (\(chat.messages.count) messages, updated \(dateText(chat.updatedAt)))"
      let attachments = attachmentNames(of: chat)
      if !attachments.isEmpty {
        line += "\n  Documents: \(attachments.joined(separator: ", "))"
      }
      return line
    }
    var out = "Other chats (\(chats.count) available):\n" + lines.joined(separator: "\n")
    if chats.count > limit {
      out += "\n(\(chats.count - limit) more not shown; raise limit to see them.)"
    }
    return out
  }

  private static func search(
    chats: [Conversation],
    arguments: [String: AgentToolArgumentValue]
  ) -> String {
    let query = (arguments["query"]?.stringValue ?? arguments["q"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return "Error: query is required." }
    guard !chats.isEmpty else { return "No other chats are available in this scope." }

    var results: [String] = []
    for chat in chats {
      guard results.count < maxResults else { break }
      var chatLines: [String] = []
      for message in chat.messages {
        guard results.count + chatLines.count < maxResults else { break }
        if let snippet = snippet(in: message.text, matching: query) {
          chatLines.append("  [\(message.role.displayName), \(dateText(message.createdAt))] \(snippet)")
        }
        for attachment in message.attachments where attachment.kind == .textFile {
          guard results.count + chatLines.count < maxResults else { break }
          if attachment.displayName.localizedCaseInsensitiveContains(query) {
            chatLines.append("  [document] \(attachment.displayName) (filename match)")
          } else if let text = attachment.text,
            let snippet = snippet(in: text, matching: query)
          {
            chatLines.append("  [document \(attachment.displayName)] \(snippet)")
          }
        }
      }
      if !chatLines.isEmpty {
        results.append("Chat \(shortID(chat)) \"\(chat.title)\":\n" + chatLines.joined(separator: "\n"))
      }
    }
    guard !results.isEmpty else {
      return "No matches for '\(query)' in \(chats.count) other chats."
    }
    return "Matches for '\(query)':\n" + results.joined(separator: "\n")
      + "\n\nUse chats_read or chats_read_attachment with a chat ID for full context."
  }

  private static func read(
    chats: [Conversation],
    arguments: [String: AgentToolArgumentValue]
  ) -> String {
    guard let chat = findChat(in: chats, arguments: arguments) else {
      return chatNotFoundMessage(chats: chats, arguments: arguments)
    }
    let limit = max(arguments["limit"]?.numberValue.map { Int($0) } ?? 30, 1)
    let messages = chat.messages.suffix(limit)
    guard !messages.isEmpty else { return "Chat \"\(chat.title)\" has no messages." }
    var lines: [String] = [
      "Chat \(shortID(chat)) \"\(chat.title)\" (\(chat.messages.count) messages, showing last \(messages.count)):"
    ]
    for message in messages {
      let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      var entry = "[\(message.role.displayName), \(dateText(message.createdAt))]"
      if !text.isEmpty {
        entry += " " + truncated(text, limit: maxMessageChars)
      }
      for attachment in message.attachments {
        entry += "\n  (attached: \(attachment.displayName))"
      }
      lines.append(entry)
    }
    return truncated(lines.joined(separator: "\n\n"), limit: maxTranscriptChars)
  }

  private static func readAttachment(
    chats: [Conversation],
    arguments: [String: AgentToolArgumentValue]
  ) -> String {
    guard let chat = findChat(in: chats, arguments: arguments) else {
      return chatNotFoundMessage(chats: chats, arguments: arguments)
    }
    let filename = (arguments["filename"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !filename.isEmpty else { return "Error: filename is required." }
    let attachments = chat.messages.flatMap(\.attachments).filter { $0.kind == .textFile }
    let match =
      attachments.first { $0.displayName.caseInsensitiveCompare(filename) == .orderedSame }
      ?? attachments.first { $0.displayName.localizedCaseInsensitiveContains(filename) }
    guard let match else {
      let known = attachments.map(\.displayName)
      return known.isEmpty
        ? "Chat \"\(chat.title)\" has no text documents attached."
        : "No document named '\(filename)' in chat \"\(chat.title)\". Available: \(known.joined(separator: ", "))"
    }
    guard let text = match.text, !text.isEmpty else {
      return "Document '\(match.displayName)' has no readable text."
    }
    return "Content of '\(match.displayName)' from chat \"\(chat.title)\":\n"
      + truncated(text, limit: maxAttachmentChars)
  }

  private static func findChat(
    in chats: [Conversation],
    arguments: [String: AgentToolArgumentValue]
  ) -> Conversation? {
    let query = (arguments["chat"]?.stringValue ?? arguments["id"]?.stringValue
      ?? arguments["title"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    let lower = query.lowercased()
    return chats.first { $0.id.uuidString.lowercased().hasPrefix(lower) }
      ?? chats.first { $0.title.caseInsensitiveCompare(query) == .orderedSame }
      ?? chats.first { $0.title.localizedCaseInsensitiveContains(query) }
  }

  private static func chatNotFoundMessage(
    chats: [Conversation],
    arguments: [String: AgentToolArgumentValue]
  ) -> String {
    let query = (arguments["chat"]?.stringValue ?? "").trimmingCharacters(
      in: .whitespacesAndNewlines)
    if query.isEmpty {
      return "Error: chat is required (an ID from chats_list or a title substring)."
    }
    return "Error: no chat matched '\(query)'. Use chats_list to see the available chats."
  }

  private static func attachmentNames(of chat: Conversation) -> [String] {
    var seen = Set<String>()
    return chat.messages.flatMap(\.attachments)
      .filter { $0.kind == .textFile }
      .map(\.displayName)
      .filter { seen.insert($0.lowercased()).inserted }
  }

  private static func snippet(in text: String, matching query: String) -> String? {
    guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    else { return nil }
    let start = text.index(
      range.lowerBound, offsetBy: -snippetContext, limitedBy: text.startIndex)
      ?? text.startIndex
    let end = text.index(
      range.upperBound, offsetBy: snippetContext, limitedBy: text.endIndex)
      ?? text.endIndex
    var snippet = String(text[start..<end])
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if start > text.startIndex { snippet = "…" + snippet }
    if end < text.endIndex { snippet += "…" }
    return snippet
  }

  private static func shortID(_ chat: Conversation) -> String {
    String(chat.id.uuidString.prefix(8)).lowercased()
  }

  private static func dateText(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private static func truncated(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return text.prefix(limit) + "\n[... truncated, \(text.count - limit) characters omitted ...]"
  }
}
