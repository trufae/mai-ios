import Foundation

enum MarkdownExporter {
  static func makeMarkdown(
    conversation: Conversation,
    includeThinking: Bool? = nil
  ) -> String {
    let summary = ConversationExportContent.summary(for: conversation)
    let shouldIncludeThinking = includeThinking ?? conversation.showThinking

    var sections: [String] = ["# \(summary.title)"]
    sections.append(
      "Started \(summary.started) · Last updated \(summary.lastUpdated)"
        + " · \(summary.messageCountText)")

    for message in conversation.messages {
      let content = ConversationExportContent.messageContent(
        for: message,
        includeThinking: shouldIncludeThinking)
      guard content.hasExportedBody else { continue }

      var parts: [String] = ["## \(message.role.displayName)"]
      for section in content.reasoningSections {
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let quoted = trimmed
          .components(separatedBy: "\n")
          .map { $0.isEmpty ? ">" : "> \($0)" }
          .joined(separator: "\n")
        parts.append("> **Reasoning**\n>\n\(quoted)")
      }
      let visible = content.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !visible.isEmpty {
        parts.append(visible)
      }
      sections.append(parts.joined(separator: "\n\n"))
    }
    return sections.joined(separator: "\n\n")
  }
}
