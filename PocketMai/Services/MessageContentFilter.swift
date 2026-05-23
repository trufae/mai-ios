import Foundation

struct RenderedMessageContent {
  var visibleText: String
  var hiddenSections: [HiddenMessageSection]
}

struct HiddenMessageSection: Identifiable {
  var id: Int
  var tag: String
  var content: String
}

enum MessageContentFilter {
  private static let hiddenTags = [
    "context", "tool_context", "tool_run", "tool_call", "think", "conversation", "speech",
  ]
  private static let promptStripTags: Set<String> = [
    "context", "tool_context", "conversation", "think", "tool_call",
  ]

  static func render(_ text: String) -> RenderedMessageContent {
    guard text.contains("<") else {
      return RenderedMessageContent(
        visibleText: normalizedVisibleText(text),
        hiddenSections: []
      )
    }

    var cursor = text.startIndex
    var visible = ""
    var hiddenSections: [HiddenMessageSection] = []

    while let opening = nextOpening(in: text, from: cursor) {
      visible += text[cursor..<opening.range.lowerBound]
      if let closing = text.range(
        of: closingPattern(for: opening.tag),
        options: [.regularExpression, .caseInsensitive],
        range: opening.range.upperBound..<text.endIndex
      ) {
        appendHiddenSection(
          tag: opening.tag,
          content: String(text[opening.range.upperBound..<closing.lowerBound]),
          hiddenSections: &hiddenSections
        )
        cursor = closing.upperBound
      } else {
        appendHiddenSection(
          tag: opening.tag,
          content: String(text[opening.range.upperBound..<text.endIndex]),
          hiddenSections: &hiddenSections
        )
        cursor = text.endIndex
      }
    }

    visible += text[cursor..<text.endIndex]
    return RenderedMessageContent(
      visibleText: normalizedVisibleText(visible),
      hiddenSections: hiddenSections
    )
  }

  static func promptSafeText(from text: String) -> String {
    conversationContextText(from: text)
  }

  static func conversationContextText(
    from text: String,
    includeReasoning: Bool = false
  ) -> String {
    var result = text
    let tags = includeReasoning ? promptStripTags.subtracting(["think"]) : promptStripTags
    for tag in tags {
      let anchor = tag == "think" ? "\\A\\s*" : ""
      let pattern = "\(anchor)<\\s*\(tag)\\b[^>]*>[\\s\\S]*?<\\s*/\\s*\(tag)\\s*>"
      result = result.replacingOccurrences(
        of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
      let unclosedPattern = "\(anchor)<\\s*\(tag)\\b[^>]*>[\\s\\S]*$"
      result = result.replacingOccurrences(
        of: unclosedPattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
    return collapseBlankLines(result).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func previewText(from text: String, maxLength: Int = 160) -> String {
    var result = render(text).visibleText
    let plainToolCallPattern = "(?im)^\\s*TOOL_CALL\\s*$[\\s\\S]*?(?:^\\s*END_TOOL_CALL\\s*$|\\z)"
    result = result.replacingOccurrences(
      of: plainToolCallPattern, with: "", options: [.regularExpression, .caseInsensitive])
    let trimmed = collapseBlankLines(result).trimmingCharacters(in: .whitespacesAndNewlines)
    return String(trimmed.prefix(maxLength))
  }

  private static func nextOpening(in text: String, from start: String.Index) -> (
    tag: String, range: Range<String.Index>
  )? {
    hiddenTags.compactMap { tag -> (tag: String, range: Range<String.Index>)? in
      guard
        let range = text.range(
          of: openingPattern(for: tag),
          options: [.regularExpression, .caseInsensitive],
          range: start..<text.endIndex
        )
      else { return nil }
      // <think> only counts as reasoning when it leads the message; otherwise
      // it's a literal mention (code spans, blockquoted examples, etc.).
      if tag == "think", text[..<range.lowerBound].contains(where: { !$0.isWhitespace }) {
        return nil
      }
      return (tag, range)
    }
    .min { lhs, rhs in lhs.range.lowerBound < rhs.range.lowerBound }
  }

  private static func openingPattern(for tag: String) -> String {
    "<\\s*\(tag)\\b[^>]*>"
  }

  private static func closingPattern(for tag: String) -> String {
    "<\\s*/\\s*\(tag)\\s*>"
  }

  private static func appendHiddenSection(
    tag: String,
    content: String,
    hiddenSections: inout [HiddenMessageSection]
  ) {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    hiddenSections.append(
      HiddenMessageSection(id: hiddenSections.count, tag: tag, content: trimmed)
    )
  }

  private static func normalizedVisibleText(_ text: String) -> String {
    collapseBlankLines(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func collapseBlankLines(_ text: String) -> String {
    var output = text
    while output.contains("\n\n\n") {
      output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return output
  }
}
