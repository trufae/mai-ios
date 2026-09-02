import Foundation

struct RenderedMessageContent {
  var visibleText: String
  var hiddenSections: [HiddenMessageSection]
  var parts: [RenderedMessagePart]
}

struct HiddenMessageSection: Identifiable {
  var id: Int
  var tag: String
  var content: String
}

struct RenderedMessagePart: Identifiable {
  enum Kind {
    case visible(String)
    case hidden(HiddenMessageSection)
  }

  var id: Int
  var kind: Kind
}

enum MessageContentFilter {
  private static let hiddenTags = [
    "context", "tool_context", "tool_run", "tool_call", "think", "conversation", "speech",
  ]
  private static let hiddenTagSet = Set(hiddenTags)
  private static let promptStripTags: Set<String> = [
    "context", "tool_context", "conversation", "think", "tool_call",
  ]

  static func render(_ text: String) -> RenderedMessageContent {
    guard text.contains("<") else {
      return RenderedMessageContent(
        visibleText: normalizedVisibleText(text),
        hiddenSections: [],
        parts: visibleParts(from: text)
      )
    }

    return scan(text, hiding: hiddenTagSet)
  }

  static func promptSafeText(from text: String) -> String {
    conversationContextText(from: text)
  }

  /// Removes model reasoning while preserving every other response byte, including tool-call
  /// envelopes that downstream parsers still need to inspect.
  static func removingReasoningSections(from text: String) -> String {
    guard text.contains("<") else { return text }
    return scan(text, hiding: ["think"], normalizeVisibleText: false).visibleText
  }

  /// Reasoning-free text for the long-press actions: drops the think blocks and
  /// tidies up the blank lines they leave behind, keeping everything else intact.
  static func textWithoutReasoning(from text: String) -> String {
    let stripped = removingReasoningSections(from: text)
    guard stripped != text else { return text }
    return collapseBlankLines(stripped.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func conversationContextText(
    from text: String,
    includeReasoning: Bool = false
  ) -> String {
    let tags = includeReasoning ? promptStripTags.subtracting(["think"]) : promptStripTags
    guard text.contains("<"), !tags.isEmpty else {
      return normalizedVisibleText(text)
    }
    return scan(text, hiding: tags).visibleText
  }

  static func previewText(from text: String, maxLength: Int = 160) -> String {
    var result = render(text).visibleText
    let plainToolCallPattern = "(?im)^\\s*TOOL_CALL\\s*$[\\s\\S]*?(?:^\\s*END_TOOL_CALL\\s*$|\\z)"
    result = result.replacingOccurrences(
      of: plainToolCallPattern, with: "", options: [.regularExpression, .caseInsensitive])
    let trimmed = collapseBlankLines(result).trimmingCharacters(in: .whitespacesAndNewlines)
    return String(trimmed.prefix(maxLength))
  }

  static func markdownPlainText(from text: String) -> String {
    text.components(separatedBy: .newlines).map { line in
      guard let attributed = try? AttributedString(markdown: line) else { return line }
      return String(attributed.characters)
    }.joined(separator: "\n")
  }

  private static func scan(
    _ text: String,
    hiding tags: Set<String>,
    normalizeVisibleText shouldNormalizeVisibleText: Bool = true
  ) -> RenderedMessageContent {
    var cursor = text.startIndex
    var visible = ""
    var hiddenSections: [HiddenMessageSection] = []
    var parts: [RenderedMessagePart] = []

    while let opening = nextOpening(in: text, from: cursor, hiding: tags) {
      appendVisibleSegment(
        text[cursor..<opening.range.lowerBound],
        visible: &visible,
        parts: &parts)
      if opening.isSelfClosing {
        cursor = opening.range.upperBound
        continue
      }
      if let closing = matchingClose(for: opening, in: text) {
        if let section = appendHiddenSection(
          tag: opening.tag,
          content: String(text[opening.range.upperBound..<closing.range.lowerBound]),
          hiddenSections: &hiddenSections
        ) {
          appendHiddenPart(section, parts: &parts)
        }
        cursor = closing.range.upperBound
      } else {
        if let section = appendHiddenSection(
          tag: opening.tag,
          content: String(text[opening.range.upperBound..<text.endIndex]),
          hiddenSections: &hiddenSections
        ) {
          appendHiddenPart(section, parts: &parts)
        }
        cursor = text.endIndex
      }
    }

    appendVisibleSegment(text[cursor..<text.endIndex], visible: &visible, parts: &parts)
    return RenderedMessageContent(
      visibleText: shouldNormalizeVisibleText ? normalizedVisibleText(visible) : visible,
      hiddenSections: hiddenSections,
      parts: parts
    )
  }

  private struct TagToken {
    let tag: String
    let isClosing: Bool
    let isSelfClosing: Bool
    let range: Range<String.Index>
  }

  private static func nextOpening(
    in text: String,
    from start: String.Index,
    hiding tags: Set<String>
  ) -> TagToken? {
    var searchStart = start
    while let token = nextTagToken(in: text, from: searchStart, matching: tags) {
      searchStart = token.range.upperBound
      if token.isClosing || !isStructuralOpening(token, in: text) {
        continue
      }
      return token
    }
    return nil
  }

  private static func matchingClose(for opening: TagToken, in text: String) -> TagToken? {
    var searchStart = opening.range.upperBound
    var nestedOpenings: [TagToken] = []
    let tags = Set([opening.tag])
    while let token = nextTagToken(in: text, from: searchStart, matching: tags) {
      searchStart = token.range.upperBound
      if token.isClosing {
        let nestedOpening = nestedOpenings.last ?? opening
        guard isStructuralClosing(token, for: nestedOpening, in: text) else {
          continue
        }
        if nestedOpenings.isEmpty {
          return token
        }
        nestedOpenings.removeLast()
      } else if !token.isSelfClosing && isStructuralOpening(token, in: text) {
        nestedOpenings.append(token)
      }
    }
    return lineDelimitedClose(for: opening, in: text)
  }

  private static func lineDelimitedClose(for opening: TagToken, in text: String) -> TagToken? {
    var searchStart = opening.range.upperBound
    var nestedDepth = 0
    let tags = Set([opening.tag])
    while let token = nextTagToken(
      in: text,
      from: searchStart,
      matching: tags,
      respectsMarkdown: false)
    {
      searchStart = token.range.upperBound
      guard isLineDelimited(token, in: text) else { continue }
      if token.isClosing {
        if nestedDepth == 0 { return token }
        nestedDepth -= 1
      } else if !token.isSelfClosing {
        nestedDepth += 1
      }
    }
    return nil
  }

  private static func nextTagToken(
    in text: String,
    from start: String.Index,
    matching tags: Set<String>,
    respectsMarkdown: Bool = true
  ) -> TagToken? {
    var index = start
    var fenceMarker: Character?
    var fenceLength = 0
    var inlineBackticks = 0

    while index < text.endIndex {
      if respectsMarkdown, inlineBackticks == 0,
        let fence = markdownFenceDelimiter(in: text, at: index)
      {
        if let marker = fenceMarker {
          if marker == fence.marker && fence.length >= fenceLength {
            fenceMarker = nil
            fenceLength = 0
          }
        } else {
          fenceMarker = fence.marker
          fenceLength = fence.length
        }
        index = fence.end
        continue
      }

      if respectsMarkdown, fenceMarker != nil {
        text.formIndex(after: &index)
        continue
      }

      if respectsMarkdown, text[index] == "`" {
        let run = repeatedCharacterRun(in: text, from: index, matching: "`")
        if inlineBackticks == 0 {
          inlineBackticks = run.length
        } else if run.length >= inlineBackticks {
          inlineBackticks = 0
        }
        index = run.end
        continue
      }

      if respectsMarkdown, inlineBackticks != 0 {
        text.formIndex(after: &index)
        continue
      }

      if text[index] == "<", let token = parseTagToken(in: text, at: index, matching: tags) {
        return token
      }
      text.formIndex(after: &index)
    }
    return nil
  }

  private static func parseTagToken(
    in text: String,
    at start: String.Index,
    matching tags: Set<String>
  ) -> TagToken? {
    guard text[start] == "<" else { return nil }
    var index = text.index(after: start)
    skipTagWhitespace(in: text, from: &index)

    var isClosing = false
    if index < text.endIndex, text[index] == "/" {
      isClosing = true
      text.formIndex(after: &index)
      skipTagWhitespace(in: text, from: &index)
    }

    let nameStart = index
    while index < text.endIndex, isTagNameCharacter(text[index]) {
      text.formIndex(after: &index)
    }
    guard nameStart < index else { return nil }

    let tag = String(text[nameStart..<index]).lowercased()
    guard tags.contains(tag) else { return nil }

    if isClosing {
      skipTagWhitespace(in: text, from: &index)
      guard index < text.endIndex, text[index] == ">" else { return nil }
      let end = text.index(after: index)
      return TagToken(tag: tag, isClosing: true, isSelfClosing: false, range: start..<end)
    }

    guard index == text.endIndex || isTagBoundary(text[index]) else { return nil }
    var end = index
    var lastNonWhitespace = index
    while end < text.endIndex, text[end] != ">" {
      if !isTagWhitespace(text[end]) {
        lastNonWhitespace = end
      }
      text.formIndex(after: &end)
    }
    guard end < text.endIndex else { return nil }
    let tokenEnd = text.index(after: end)
    let isSelfClosing = lastNonWhitespace < end && text[lastNonWhitespace] == "/"
    return TagToken(tag: tag, isClosing: false, isSelfClosing: isSelfClosing, range: start..<tokenEnd)
  }

  private static func isStructuralOpening(_ token: TagToken, in text: String) -> Bool {
    guard token.tag == "think" else { return true }
    return isLinePrefixWhitespace(in: text, before: token.range.lowerBound)
  }

  private static func isStructuralClosing(
    _ token: TagToken,
    for opening: TagToken,
    in text: String
  ) -> Bool {
    guard token.tag == "think" else { return true }
    return isLinePrefixWhitespace(in: text, before: token.range.lowerBound)
      || isSameLine(in: text, from: opening.range.lowerBound, to: token.range.lowerBound)
      || (isImmediatelyAfterNonWhitespace(in: text, at: token.range.lowerBound)
        && isLineSuffixWhitespace(in: text, after: token.range.upperBound))
  }

  private static func isLineDelimited(_ token: TagToken, in text: String) -> Bool {
    isLinePrefixWhitespace(in: text, before: token.range.lowerBound)
      && isLineSuffixWhitespace(in: text, after: token.range.upperBound)
  }

  private static func skipTagWhitespace(in text: String, from index: inout String.Index) {
    while index < text.endIndex, isTagWhitespace(text[index]) {
      text.formIndex(after: &index)
    }
  }

  private static func isTagNameCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "-"
  }

  private static func isTagBoundary(_ character: Character) -> Bool {
    isTagWhitespace(character) || character == ">" || character == "/"
  }

  private static func isTagWhitespace(_ character: Character) -> Bool {
    character == " " || character == "\t" || character == "\n" || character == "\r"
  }

  private static func markdownFenceDelimiter(
    in text: String,
    at index: String.Index
  ) -> (marker: Character, length: Int, end: String.Index)? {
    guard isLinePrefixWhitespace(in: text, before: index),
      text[index] == "`" || text[index] == "~"
    else {
      return nil
    }
    let run = repeatedCharacterRun(in: text, from: index, matching: text[index])
    guard run.length >= 3 else { return nil }
    return (text[index], run.length, run.end)
  }

  private static func repeatedCharacterRun(
    in text: String,
    from start: String.Index,
    matching character: Character
  ) -> (length: Int, end: String.Index) {
    var index = start
    var length = 0
    while index < text.endIndex, text[index] == character {
      length += 1
      text.formIndex(after: &index)
    }
    return (length, index)
  }

  private static func isLinePrefixWhitespace(in text: String, before index: String.Index) -> Bool {
    var cursor = index
    while cursor > text.startIndex {
      let previous = text.index(before: cursor)
      if text[previous] == "\n" || text[previous] == "\r" {
        return true
      }
      if !text[previous].isWhitespace {
        return false
      }
      cursor = previous
    }
    return true
  }

  private static func isLineSuffixWhitespace(in text: String, after index: String.Index) -> Bool {
    var cursor = index
    while cursor < text.endIndex {
      if text[cursor] == "\n" || text[cursor] == "\r" {
        return true
      }
      if !text[cursor].isWhitespace {
        return false
      }
      text.formIndex(after: &cursor)
    }
    return true
  }

  private static func isImmediatelyAfterNonWhitespace(
    in text: String,
    at index: String.Index
  ) -> Bool {
    guard index > text.startIndex else { return false }
    let previous = text.index(before: index)
    return !text[previous].isWhitespace
  }

  private static func isSameLine(
    in text: String,
    from start: String.Index,
    to end: String.Index
  ) -> Bool {
    var cursor = start
    while cursor < end {
      if text[cursor] == "\n" || text[cursor] == "\r" {
        return false
      }
      text.formIndex(after: &cursor)
    }
    return true
  }

  private static func appendHiddenSection(
    tag: String,
    content: String,
    hiddenSections: inout [HiddenMessageSection]
  ) -> HiddenMessageSection? {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let section = HiddenMessageSection(id: hiddenSections.count, tag: tag, content: trimmed)
    hiddenSections.append(section)
    return section
  }

  private static func appendVisibleSegment(
    _ segment: Substring,
    visible: inout String,
    parts: inout [RenderedMessagePart]
  ) {
    guard !segment.isEmpty else { return }
    visible += segment
    let normalized = normalizedVisibleText(String(segment))
    guard !normalized.isEmpty else { return }
    parts.append(RenderedMessagePart(id: parts.count, kind: .visible(normalized)))
  }

  private static func appendHiddenPart(
    _ section: HiddenMessageSection,
    parts: inout [RenderedMessagePart]
  ) {
    parts.append(RenderedMessagePart(id: parts.count, kind: .hidden(section)))
  }

  private static func visibleParts(from text: String) -> [RenderedMessagePart] {
    let visible = normalizedVisibleText(text)
    guard !visible.isEmpty else { return [] }
    return [RenderedMessagePart(id: 0, kind: .visible(visible))]
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
