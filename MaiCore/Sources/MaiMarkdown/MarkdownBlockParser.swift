import Foundation

/// One item of an ordered list, with the label the author wrote (`1.`, `a)`).
public struct MarkdownListItem: Equatable, Sendable {
  public var label: String
  public var text: String

  public init(label: String, text: String) {
    self.label = label
    self.text = text
  }
}

public struct MarkdownTaskItem: Equatable, Sendable {
  public var checked: Bool
  public var text: String

  public init(checked: Bool, text: String) {
    self.checked = checked
    self.text = text
  }
}

public struct MarkdownFootnote: Equatable, Sendable {
  public var key: String
  public var text: String

  public init(key: String, text: String) {
    self.key = key
    self.text = text
  }
}

/// A block of a markdown document. Paragraph and quote text keep their line
/// breaks so a renderer can decide whether they are soft or hard.
public enum MarkdownBlock: Equatable, Sendable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case quote(String)
  case rule
  case code(language: String, code: String)
  case table(MarkdownTable)
  case bullets([String])
  case ordered([MarkdownListItem])
  case tasks([MarkdownTaskItem])
  case footnotes([MarkdownFootnote])
}

/// Splits a complete markdown text into blocks, for renderers that lay out a
/// whole document at once — exporters, mostly — using the same line rules
/// the streaming renderer applies.
public enum MarkdownBlockParser {
  public static func blocks(from text: String) -> [MarkdownBlock] {
    let lines = text.components(separatedBy: .newlines)
    var state = State()
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if state.fence != nil {
        if case .fence = MarkdownLineClassifier.classify(line) {
          state.closeFence()
        } else {
          state.fence?.lines.append(line)
        }
        index += 1
        continue
      }
      if MarkdownTable.isCandidateLine(line), index + 1 < lines.count,
        MarkdownTable.isSeparatorLine(lines[index + 1])
      {
        var tableLines = [line, lines[index + 1]]
        var cursor = index + 2
        while cursor < lines.count, MarkdownTable.isCandidateLine(lines[cursor]) {
          tableLines.append(lines[cursor])
          cursor += 1
        }
        if let table = MarkdownTable.parse(tableLines) {
          state.flush()
          state.blocks.append(.table(table))
          index = cursor
          continue
        }
      }
      switch MarkdownLineClassifier.classify(line) {
      case .blank:
        state.flush()
      case .heading(let level, let text):
        state.flush()
        state.blocks.append(.heading(level: level, text: text))
      case .rule:
        state.flush()
        state.blocks.append(.rule)
      case .fence(let language):
        state.flush()
        state.fence = (language, [])
      case .quote(let text):
        state.add(.quote, text)
      case .bullet(_, let text):
        state.add(.bullets, text)
      case .ordered(_, let label, let text):
        state.add(.ordered, text, label: label)
      case .task(_, let checked, let text):
        state.add(.tasks, text, checked: checked)
      case .footnote(let key, let text):
        state.add(.footnotes, text, label: key)
      case .paragraph(let text):
        state.continueOrStart(text)
      }
      index += 1
    }
    state.closeFence()
    state.flush()
    return state.blocks
  }

  private enum PendingKind {
    case paragraph, quote, bullets, ordered, tasks, footnotes
  }

  private struct PendingLine {
    var text: String
    var label = ""
    var checked = false
  }

  private struct State {
    var blocks: [MarkdownBlock] = []
    var fence: (language: String, lines: [String])?
    private var pendingKind: PendingKind?
    private var pending: [PendingLine] = []

    mutating func add(_ kind: PendingKind, _ text: String, label: String = "", checked: Bool = false) {
      if pendingKind != kind { flush() }
      pendingKind = kind
      pending.append(PendingLine(text: text, label: label, checked: checked))
    }

    /// A plain line right after a list item continues that item; after
    /// anything else it is paragraph text.
    mutating func continueOrStart(_ text: String) {
      let indented = text.first == " " || text.first == "\t"
      if let kind = pendingKind, [.bullets, .ordered, .tasks, .footnotes].contains(kind), indented,
        !pending.isEmpty
      {
        pending[pending.count - 1].text += " " + text.trimmingCharacters(in: .whitespaces)
        return
      }
      add(.paragraph, text)
    }

    mutating func closeFence() {
      guard let fence else { return }
      blocks.append(.code(language: fence.language, code: fence.lines.joined(separator: "\n")))
      self.fence = nil
    }

    mutating func flush() {
      defer {
        pendingKind = nil
        pending.removeAll()
      }
      guard let pendingKind, !pending.isEmpty else { return }
      switch pendingKind {
      case .paragraph:
        blocks.append(.paragraph(pending.map(\.text).joined(separator: "\n")))
      case .quote:
        blocks.append(.quote(pending.map(\.text).joined(separator: "\n")))
      case .bullets:
        blocks.append(.bullets(pending.map(\.text)))
      case .ordered:
        blocks.append(.ordered(pending.map { MarkdownListItem(label: $0.label, text: $0.text) }))
      case .tasks:
        blocks.append(.tasks(pending.map { MarkdownTaskItem(checked: $0.checked, text: $0.text) }))
      case .footnotes:
        blocks.append(.footnotes(pending.map { MarkdownFootnote(key: $0.label, text: $0.text) }))
      }
    }
  }
}
