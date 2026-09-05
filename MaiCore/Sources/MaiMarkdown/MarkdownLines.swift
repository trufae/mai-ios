import Foundation

/// The kind of a complete markdown line, for callers that classify lines
/// themselves; the layout uses ``MarkdownLineClassifier/analyze(_:complete:)``.
public enum MarkdownLineKind: Equatable, Sendable {
  case blank
  case paragraph(String)
  case heading(level: Int, text: String)
  case rule
  case fence(language: String)
  case quote(String)
  case bullet(indent: Int, text: String)
  case ordered(indent: Int, label: String, text: String)
  case task(indent: Int, checked: Bool, text: String)
  case footnote(key: String, text: String)
}

/// The block kind a line was recognised as, before its content is known.
public enum MarkdownLineBase: Equatable, Sendable {
  case paragraph
  case heading(level: Int)
  case quote
  case bullet(indent: Int)
  case ordered(indent: Int, label: String)
  case task(indent: Int, checked: Bool)
  case footnote(key: String)

  /// Whether the whitespace between the marker and the content is dropped.
  var trimsLeadingContent: Bool {
    if case .paragraph = self { return false }
    return true
  }
}

/// What to do with the characters of a line seen so far.
public enum MarkdownLineAnalysis: Equatable, Sendable {
  /// More characters are needed before the kind is known.
  case needMore
  /// The whole line is needed: a fence, table row, or rule candidate.
  case hold
  /// The kind is known; content starts at the given character offset.
  case decided(MarkdownLineBase, contentStart: Int)
  case blank
  case rule
  case fence(language: String)
}

public enum MarkdownLineClassifier {
  public static func classify(_ line: String) -> MarkdownLineKind {
    let chars = Array(line)
    switch analyze(chars, complete: true) {
    case .blank:
      return .blank
    case .rule:
      return .rule
    case .fence(let language):
      return .fence(language: language)
    case .needMore, .hold:
      return .paragraph(line)
    case .decided(let base, let contentStart):
      var content = String(chars[contentStart...])
      if base.trimsLeadingContent {
        content = String(content.drop(while: { $0 == " " || $0 == "\t" }))
      }
      switch base {
      case .paragraph: return .paragraph(line)
      case .heading(let level): return .heading(level: level, text: content)
      case .quote: return .quote(content)
      case .bullet(let indent): return .bullet(indent: indent, text: content)
      case .ordered(let indent, let label):
        return .ordered(indent: indent, label: label, text: content)
      case .task(let indent, let checked):
        return .task(indent: indent, checked: checked, text: content)
      case .footnote(let key): return .footnote(key: key, text: content)
      }
    }
  }

  /// Classifies the characters of a line. With `complete` false the line may
  /// still grow, so ambiguous prefixes ask for more input instead of guessing.
  public static func analyze(_ chars: [Character], complete: Bool) -> MarkdownLineAnalysis {
    var index = 0
    var indent = 0
    while index < chars.count, chars[index] == " " || chars[index] == "\t" {
      indent += chars[index] == "\t" ? 4 : 1
      index += 1
    }
    guard index < chars.count else { return complete ? .blank : .needMore }
    let level = indent / 2
    let first = chars[index]

    switch first {
    case "`":
      let end = run(of: "`", from: index, in: chars)
      if end - index >= 3 {
        guard complete else { return .hold }
        let language = String(chars[end...]).trimmingCharacters(in: .whitespaces)
        return .fence(language: language)
      }
      if end == chars.count, !complete { return .needMore }
      return .decided(.paragraph, contentStart: 0)

    case "#":
      let end = run(of: "#", from: index, in: chars)
      let hashes = end - index
      if hashes > 6 { return .decided(.paragraph, contentStart: 0) }
      if end == chars.count { return complete ? .decided(.paragraph, contentStart: 0) : .needMore }
      guard isSpace(chars[end]) else { return .decided(.paragraph, contentStart: 0) }
      return .decided(.heading(level: hashes), contentStart: end)

    case ">":
      return .decided(.quote, contentStart: index + 1)

    case "-", "*", "+", "_":
      let markerEnd = run(of: first, from: index, in: chars)
      let markers = markerEnd - index
      var afterSpaces = markerEnd
      while afterSpaces < chars.count, isSpace(chars[afterSpaces]) { afterSpaces += 1 }
      if afterSpaces == chars.count {
        // Only markers and spaces so far: a rule, an empty item, or a paragraph.
        if !complete {
          if first == "_" && markers == 1 { return .decided(.paragraph, contentStart: 0) }
          return .needMore
        }
        if markers >= 3, first != "+" { return .rule }
        if markers == 1, first != "_", markerEnd < chars.count {
          return .decided(.bullet(indent: level), contentStart: afterSpaces)
        }
        return .decided(.paragraph, contentStart: 0)
      }
      guard markers == 1, first != "_", isSpace(chars[markerEnd]) else {
        return .decided(.paragraph, contentStart: 0)
      }
      if chars[afterSpaces] == "[" {
        guard afterSpaces + 2 < chars.count else {
          return complete ? .decided(.bullet(indent: level), contentStart: afterSpaces) : .needMore
        }
        let mark = chars[afterSpaces + 1]
        if (mark == " " || mark == "x" || mark == "X"), chars[afterSpaces + 2] == "]" {
          let boxEnd = afterSpaces + 3
          if boxEnd == chars.count {
            return complete
              ? .decided(.task(indent: level, checked: mark != " "), contentStart: boxEnd)
              : .needMore
          }
          if isSpace(chars[boxEnd]) {
            return .decided(.task(indent: level, checked: mark != " "), contentStart: boxEnd)
          }
        }
      }
      return .decided(.bullet(indent: level), contentStart: afterSpaces)

    case "0"..."9":
      var end = index
      while end < chars.count, chars[end].isASCII, chars[end].isNumber, end - index < 10 { end += 1 }
      if end - index > 9 { return .decided(.paragraph, contentStart: 0) }
      if end == chars.count { return complete ? .decided(.paragraph, contentStart: 0) : .needMore }
      guard chars[end] == "." || chars[end] == ")" else {
        return .decided(.paragraph, contentStart: 0)
      }
      if end + 1 == chars.count { return complete ? .decided(.paragraph, contentStart: 0) : .needMore }
      guard isSpace(chars[end + 1]) else { return .decided(.paragraph, contentStart: 0) }
      return .decided(
        .ordered(indent: level, label: String(chars[index...end])), contentStart: end + 1)

    case "|":
      return .hold

    case "[":
      guard index + 1 < chars.count else {
        return complete ? .decided(.paragraph, contentStart: 0) : .needMore
      }
      guard chars[index + 1] == "^" else { return .decided(.paragraph, contentStart: 0) }
      var end = index + 2
      while end < chars.count, chars[end] != "]" {
        if chars[end].isWhitespace || end - index > 64 { return .decided(.paragraph, contentStart: 0) }
        end += 1
      }
      guard end < chars.count, end > index + 2 else {
        return complete || end - index > 64 ? .decided(.paragraph, contentStart: 0) : .needMore
      }
      guard end + 1 < chars.count else {
        return complete ? .decided(.paragraph, contentStart: 0) : .needMore
      }
      guard chars[end + 1] == ":" else { return .decided(.paragraph, contentStart: 0) }
      return .decided(.footnote(key: String(chars[(index + 2)..<end])), contentStart: end + 2)

    default:
      return .decided(.paragraph, contentStart: 0)
    }
  }

  private static func run(of char: Character, from start: Int, in chars: [Character]) -> Int {
    var end = start
    while end < chars.count, chars[end] == char { end += 1 }
    return end
  }

  private static func isSpace(_ char: Character) -> Bool {
    char == " " || char == "\t"
  }
}
