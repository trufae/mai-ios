import Foundation

enum TTSSpeechTextSanitizer {
  static func sanitized(_ text: String) -> String {
    var result = text
    result = replacing(pattern: "<[^>]+>", in: result, with: " ")
    result = decodeCommonHTMLEntities(result)
    result = replacing(pattern: #"!\[([^\]]*)\]\([^)]+\)"#, in: result, with: "$1")
    result = replacing(pattern: #"\[([^\]]+)\]\([^)]+\)"#, in: result, with: "$1")
    result = replacing(pattern: #"(?m)^\s{0,3}#{1,6}\s+"#, in: result, with: "")
    result = replacing(pattern: #"(?m)^\s*[-*+]\s+\[[ xX]\]\s+"#, in: result, with: "")
    result = replacing(pattern: #"(?m)^\s*[-*+]\s+"#, in: result, with: "")
    result = replacing(pattern: #"(?m)^\s*>\s?"#, in: result, with: "")
    result = replacing(pattern: #"`{1,3}"#, in: result, with: "")
    result = replacing(pattern: "[\\*_~|\\\\#>\\[\\]{}()]", in: result, with: " ")
    result = result.replacingOccurrences(of: "<", with: " ")
      .replacingOccurrences(of: ">", with: " ")
      .replacingOccurrences(of: "&", with: " and ")
    result = removeEmoji(from: result)
    result = collapseWhitespace(result)
    return result
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
