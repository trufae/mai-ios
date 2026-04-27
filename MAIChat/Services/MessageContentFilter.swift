import Foundation

struct RenderedMessageContent {
  var visibleText: String
  var hiddenSections: [HiddenMessageSection]
}

struct HiddenMessageSection: Identifiable {
  var id: Int
  var tag: String
  var content: String

  var title: String {
    switch tag {
    case "think": "Reasoning"
    case "tool_context": "Tool Context"
    case "conversation": "Prompt Transcript"
    default: tag
    }
  }

  var systemImage: String {
    switch tag {
    case "think": "brain"
    case "tool_context": "wrench.and.screwdriver"
    case "conversation": "text.bubble"
    default: "curlybraces"
    }
  }

  var rawText: String {
    "<\(tag)>\n\(content)\n</\(tag)>"
  }
}

enum MessageContentFilter {
  private static let hiddenTags = ["tool_context", "tool_run", "think", "conversation"]
  private static let promptStripTags: Set<String> = ["tool_context", "conversation", "think"]

  static func render(_ text: String) -> RenderedMessageContent {
    var cursor = text.startIndex
    var visible = ""
    var hiddenSections: [HiddenMessageSection] = []

    while let opening = nextOpening(in: text, from: cursor) {
      visible += text[cursor..<opening.range.lowerBound]
      let closeTag = "</\(opening.tag)>"
      if let closing = text.range(
        of: closeTag,
        options: [.caseInsensitive],
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
    var result = text
    for tag in promptStripTags {
      let pattern = "<\(tag)>[\\s\\S]*?</\(tag)>"
      result = result.replacingOccurrences(
        of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
    while result.contains("\n\n\n") {
      result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func nextOpening(in text: String, from start: String.Index) -> (
    tag: String, range: Range<String.Index>
  )? {
    hiddenTags.compactMap { tag in
      text.range(
        of: "<\(tag)>",
        options: [.caseInsensitive],
        range: start..<text.endIndex
      ).map { (tag, $0) }
    }
    .min { lhs, rhs in lhs.range.lowerBound < rhs.range.lowerBound }
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
    var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while output.contains("\n\n\n") {
      output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return output
  }
}
