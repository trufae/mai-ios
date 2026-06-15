import Foundation

enum MarkdownInlineCodeSpan {
  static func span(in chars: [Character], at index: Int) -> (code: String, end: Int)? {
    guard index < chars.count, chars[index] == "`", !isEscaped(chars, at: index) else {
      return nil
    }

    let opening = backtickRun(in: chars, at: index)
    var cursor = opening.end
    while cursor < chars.count {
      guard chars[cursor] == "`", !isEscaped(chars, at: cursor) else {
        cursor += 1
        continue
      }

      let closing = backtickRun(in: chars, at: cursor)
      if closing.length >= opening.length {
        return (String(chars[opening.end..<cursor]), closing.end)
      }
      cursor = closing.end
    }
    return nil
  }

  private static func backtickRun(in chars: [Character], at index: Int) -> (
    length: Int, end: Int
  ) {
    var cursor = index
    while cursor < chars.count, chars[cursor] == "`" {
      cursor += 1
    }
    return (cursor - index, cursor)
  }

  private static func isEscaped(_ chars: [Character], at index: Int) -> Bool {
    guard index > 0 else { return false }
    var slashCount = 0
    var cursor = index - 1
    while cursor >= 0, chars[cursor] == "\\" {
      slashCount += 1
      cursor -= 1
    }
    return slashCount % 2 == 1
  }
}

enum MarkdownWebURL {
  static func url(from raw: String) -> URL? {
    guard let string = normalizedString(from: raw) else { return nil }
    return URL(string: string)
  }

  static func normalizedString(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host != nil
    else {
      return nil
    }
    return trimmed
  }
}
