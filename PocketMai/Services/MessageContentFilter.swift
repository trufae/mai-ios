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
    "context", "tool_context", "tool_run", "tool_call", "conversation", "speech",
  ]
  private static let promptStripTags: Set<String> = [
    "context", "tool_context", "conversation", "tool_call",
  ]

  static func render(_ text: String) -> RenderedMessageContent {
    guard text.contains("<") else {
      return RenderedMessageContent(
        visibleText: normalizedVisibleText(text),
        hiddenSections: []
      )
    }

    var hiddenSections: [HiddenMessageSection] = []
    var cursor = text.startIndex
    var visible = ""

    // Reasoning is always emitted as a single leading <think>...</think> block.
    // Treat only the leading block as reasoning; later occurrences (examples in
    // code spans, blockquotes, etc.) are preserved as visible text.
    if let leading = extractLeadingThinkBlock(in: text) {
      appendHiddenSection(
        tag: "think",
        content: leading.content,
        hiddenSections: &hiddenSections
      )
      cursor = leading.remainderStart
    }

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
    // Strip only the leading <think>...</think> block (and its unclosed variant)
    // so that literal `<think>` examples inside the response body are preserved.
    if !includeReasoning {
      let leadingThink = "\\A\\s*<\\s*think\\b[^>]*>[\\s\\S]*?<\\s*/\\s*think\\s*>"
      result = result.replacingOccurrences(
        of: leadingThink, with: "", options: [.regularExpression, .caseInsensitive])
      let unclosedLeadingThink = "\\A\\s*<\\s*think\\b[^>]*>[\\s\\S]*$"
      result = result.replacingOccurrences(
        of: unclosedLeadingThink, with: "", options: [.regularExpression, .caseInsensitive])
    }
    for tag in promptStripTags {
      let pattern = "<\\s*\(tag)\\b[^>]*>[\\s\\S]*?<\\s*/\\s*\(tag)\\s*>"
      result = result.replacingOccurrences(
        of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
      let unclosedPattern = "<\\s*\(tag)\\b[^>]*>[\\s\\S]*$"
      result = result.replacingOccurrences(
        of: unclosedPattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
    return collapseBlankLines(result).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func extractLeadingThinkBlock(in text: String) -> (
    content: String, remainderStart: String.Index
  )? {
    // Allow only whitespace before the opening <think> tag so we match the
    // model's reasoning preamble and never an in-body literal mention.
    let openingRegex = "\\A\\s*<\\s*think\\b[^>]*>"
    guard
      let opening = text.range(
        of: openingRegex,
        options: [.regularExpression, .caseInsensitive]
      )
    else {
      return nil
    }
    if let closing = text.range(
      of: closingPattern(for: "think"),
      options: [.regularExpression, .caseInsensitive],
      range: opening.upperBound..<text.endIndex
    ) {
      return (
        content: String(text[opening.upperBound..<closing.lowerBound]),
        remainderStart: closing.upperBound
      )
    }
    return (
      content: String(text[opening.upperBound..<text.endIndex]),
      remainderStart: text.endIndex
    )
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
    hiddenTags.compactMap { tag in
      text.range(
        of: openingPattern(for: tag),
        options: [.regularExpression, .caseInsensitive],
        range: start..<text.endIndex
      ).map { (tag, $0) }
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
