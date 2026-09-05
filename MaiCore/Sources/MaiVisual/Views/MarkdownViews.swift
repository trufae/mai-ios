import Foundation
import MaiMarkdown
import SwiftTUIRuntime

/// Message markdown laid out as styled lines at the pane width.
struct MarkdownMessageText: View {
  let id: String
  let text: String
  let width: Int

  var body: some View {
    Text(
      MarkdownRichText.content(
        for: MarkdownRenderCache.lines(id: id, text: text, width: width)))
  }
}

/// Maps styled markdown spans to SwiftTUI text.
@MainActor
enum MarkdownRichText {
  static func content(for lines: [MarkdownStyledLine]) -> Text.RichContent {
    var interpolation = Text.StringInterpolation(literalCapacity: 0, interpolationCount: 0)
    for (index, line) in lines.enumerated() {
      if index > 0 { interpolation.appendLiteral("\n") }
      for span in line where !span.text.isEmpty {
        if span.style == .plain {
          interpolation.appendLiteral(span.text)
        } else {
          interpolation.appendInterpolation(styledText(span))
        }
      }
    }
    return Text.RichContent(stringInterpolation: interpolation)
  }

  static func styledText(_ span: MarkdownSpan) -> Text {
    var text = Text(span.text)
    switch span.style.role {
    case .body:
      break
    case .heading:
      text = text.bold().foregroundStyle(.tint)
    case .quote:
      text = text.italic().foregroundStyle(.muted)
    case .code:
      text = text.foregroundStyle(.success)
    case .fence, .linkDestination:
      text = text.faint().foregroundStyle(.muted)
    case .listMarker, .footnoteLabel:
      text = text.foregroundStyle(.warning)
    case .taskMarker(let checked):
      text = text.foregroundStyle(checked ? .success : .warning)
    case .tableBorder, .rule:
      text = text.foregroundStyle(.separator)
    case .tableHeader:
      text = text.bold()
    }
    let inline = span.style.inline
    if inline.contains(.bold) { text = text.bold() }
    if inline.contains(.italic) { text = text.italic() }
    if inline.contains(.strikethrough) { text = text.strikethrough() }
    if inline.contains(.code) { text = text.foregroundStyle(.success) }
    if inline.contains(.link) { text = text.underline().foregroundStyle(.link) }
    return text
  }
}

/// Keeps the layout state of each message so a streaming reply only lays out
/// the text that arrived since the last frame, and finished messages are not
/// parsed again on every redraw.
@MainActor
enum MarkdownRenderCache {
  private struct Entry {
    var text: String
    var width: Int
    var layout: MarkdownStreamLayout
    var document: MarkdownStyledDocument
    var lines: [MarkdownStyledLine]
  }

  private static var entries: [String: Entry] = [:]
  private static var order: [String] = []
  private static let maxEntries = 512

  static func lines(id: String, text: String, width: Int) -> [MarkdownStyledLine] {
    let width = max(20, width)
    var entry: Entry
    if let existing = entries[id], existing.width == width, text.hasPrefix(existing.text) {
      if existing.text == text {
        touch(id)
        return existing.lines
      }
      entry = existing
      let start = text.utf8.index(text.utf8.startIndex, offsetBy: existing.text.utf8.count)
      entry.document.apply(entry.layout.feed(String(text[start...])))
      entry.text = text
    } else {
      var layout = MarkdownStreamLayout(options: MarkdownLayoutOptions(width: width))
      var document = MarkdownStyledDocument()
      document.apply(layout.feed(text))
      entry = Entry(text: text, width: width, layout: layout, document: document, lines: [])
    }
    var finalLayout = entry.layout
    var finalDocument = entry.document
    finalDocument.apply(finalLayout.flush())
    entry.lines = finalDocument.allLines
    entries[id] = entry
    touch(id)
    return entry.lines
  }

  static func removeAll() {
    entries.removeAll()
    order.removeAll()
  }

  private static func touch(_ id: String) {
    if let index = order.firstIndex(of: id) { order.remove(at: index) }
    order.append(id)
    while order.count > maxEntries, let oldest = order.first {
      order.removeFirst()
      entries.removeValue(forKey: oldest)
    }
  }
}
