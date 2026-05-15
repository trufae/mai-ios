import Foundation

enum TTSSpeechTextSanitizer {
  static func sanitized(_ text: String, skipTechnicalContent: Bool = true) -> String {
    var result = text
    if skipTechnicalContent {
      result = removeMarkdownCodeBlocks(from: result)
      result = removeJSONBlocks(from: result)
      result = removeXMLBlocks(from: result)
      result = removeURLs(from: result)
    }
    result = decodeCommonHTMLEntities(result)
    result = replacing(pattern: #"!\[([^\]]*)\]\([^)]+\)"#, in: result, with: "$1")
    result = replacing(pattern: #"\[([^\]]+)\]\([^)]+\)"#, in: result, with: "$1")
    result = replacing(pattern: #"(?m)^\s{0,3}#{1,6}\s+"#, in: result, with: "")
    result = replacing(pattern: #"(?m)^\s*[-*+]\s+\[[ xX]\]\s+"#, in: result, with: "")
    result = replacing(pattern: #"(?m)^\s*[-*+]\s+"#, in: result, with: "")
    result = replacing(pattern: #"(?m)^\s*>\s?"#, in: result, with: "")
    if skipTechnicalContent {
      result = replacing(pattern: #"`[^`\n]+`"#, in: result, with: " ")
    }
    result = replacing(pattern: #"`{1,3}"#, in: result, with: "")
    result = replacing(pattern: "<[^>]+>", in: result, with: " ")
    result = replacing(pattern: "[\\*_~|\\\\#>\\[\\]{}()]", in: result, with: " ")
    result = result.replacingOccurrences(of: "<", with: " ")
      .replacingOccurrences(of: ">", with: " ")
      .replacingOccurrences(of: "&", with: " and ")
    result = removeEmoji(from: result)
    result = collapseWhitespace(result)
    return result
  }

  private static func removeMarkdownCodeBlocks(from text: String) -> String {
    var result = replacing(
      pattern: #"(?ms)^ {0,3}`{3,}.*?$[\s\S]*?^ {0,3}`{3,}\s*$"#,
      in: text,
      with: " ")
    result = replacing(
      pattern: #"(?ms)^ {0,3}~{3,}.*?$[\s\S]*?^ {0,3}~{3,}\s*$"#,
      in: result,
      with: " ")
    return replacing(
      pattern: #"(?m)(?:^(?: {4}|\t).*(?:\n|$))+"#,
      in: result,
      with: " ")
  }

  private static func removeURLs(from text: String) -> String {
    var result = replacing(
      pattern: #"\b(?:https?|ftp)://[^\s<>\[\]{}"']+"#,
      in: text,
      with: " ")
    result = replacing(
      pattern: #"\bwww\.[^\s<>\[\]{}"']+"#,
      in: result,
      with: " ")
    return replacing(
      pattern: #"\bmailto:[^\s<>\[\]{}"']+"#,
      in: result,
      with: " ")
  }

  private static func removeXMLBlocks(from text: String) -> String {
    let blockPattern = #"(?ms)^\s*<([A-Za-z][A-Za-z0-9._:-]*)(?:\s+[^>]*)?>[\s\S]*?</\1>\s*$"#
    var result = replacing(pattern: blockPattern, in: text, with: " ")
    result = replacing(
      pattern:
        #"(?ms)^\s*<\?xml\b[\s\S]*?(?:\?>\s*)?(?:<([A-Za-z][A-Za-z0-9._:-]*)(?:\s+[^>]*)?>[\s\S]*?</\1>)?\s*$"#,
      in: result,
      with: " ")
    return replacing(
      pattern: #"(?ms)^\s*<([A-Za-z][A-Za-z0-9._:-]*)(?:\s+[^>]*)?>[\s\S]*$"#,
      in: result,
      with: " ")
  }

  private static func removeJSONBlocks(from text: String) -> String {
    var output = ""
    var cursor = text.startIndex

    while cursor < text.endIndex {
      guard let start = nextJSONBlockStart(in: text, from: cursor) else {
        output += text[cursor..<text.endIndex]
        break
      }

      guard let end = jsonBlockEnd(in: text, from: start) else {
        output += text[cursor..<text.endIndex]
        break
      }

      let candidate = String(text[start..<end])
      guard isLikelyJSONBlock(candidate) else {
        output += text[cursor...start]
        cursor = text.index(after: start)
        continue
      }

      output += text[cursor..<start]
      output += " "
      cursor = end
    }

    return output
  }

  private static func nextJSONBlockStart(in text: String, from start: String.Index)
    -> String.Index?
  {
    var lineStart = start
    while lineStart < text.endIndex {
      let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
      var firstNonWhitespace = lineStart
      while firstNonWhitespace < lineEnd,
        text[firstNonWhitespace].isWhitespace
      {
        firstNonWhitespace = text.index(after: firstNonWhitespace)
      }
      if firstNonWhitespace < lineEnd,
        text[firstNonWhitespace] == "{" || text[firstNonWhitespace] == "["
      {
        return firstNonWhitespace
      }
      guard lineEnd < text.endIndex else { break }
      lineStart = text.index(after: lineEnd)
    }
    return nil
  }

  private static func jsonBlockEnd(in text: String, from start: String.Index) -> String.Index? {
    var stack: [Character] = []
    var cursor = start
    var inString = false
    var escaped = false

    while cursor < text.endIndex {
      let character = text[cursor]
      defer { cursor = text.index(after: cursor) }

      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        continue
      }

      switch character {
      case "\"":
        inString = true
      case "{":
        stack.append("}")
      case "[":
        stack.append("]")
      case "}", "]":
        guard stack.last == character else { return nil }
        stack.removeLast()
        if stack.isEmpty {
          return text.index(after: cursor)
        }
      default:
        break
      }
    }

    return nil
  }

  private static func isLikelyJSONBlock(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 2,
      (trimmed.first == "{" && trimmed.last == "}")
        || (trimmed.first == "[" && trimmed.last == "]")
    else {
      return false
    }
    return trimmed.contains("\n") || trimmed.contains(#"""#) || trimmed.contains(":")
  }

  private static func decodeCommonHTMLEntities(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&#160;", with: " ")
      .replacingOccurrences(of: "&amp;", with: " and ")
      .replacingOccurrences(of: "&#38;", with: " and ")
      .replacingOccurrences(of: "&lt;", with: " ")
      .replacingOccurrences(of: "&#60;", with: " ")
      .replacingOccurrences(of: "&gt;", with: " ")
      .replacingOccurrences(of: "&#62;", with: " ")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#34;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&apos;", with: "'")
  }

  private static func removeEmoji(from text: String) -> String {
    String(
      text.filter { character in
        !character.unicodeScalars.contains { scalar in
          scalar.properties.isEmojiPresentation
            || scalar.properties.isEmojiModifier
            || scalar.properties.isEmojiModifierBase
            || scalar.value == 0xFE0F
            || scalar.value == 0x200D
            || isEmojiRange(scalar.value)
        }
      })
  }

  private static func isEmojiRange(_ value: UInt32) -> Bool {
    switch value {
    case 0x1F000...0x1FAFF, 0x2600...0x27BF:
      return true
    default:
      return false
    }
  }

  private static func collapseWhitespace(_ text: String) -> String {
    text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func replacing(pattern: String, in text: String, with replacement: String)
    -> String
  {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return text
    }
    return regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: NSRange(location: 0, length: (text as NSString).length),
      withTemplate: replacement
    )
  }
}
