import Foundation

/// Markdown emitted by the document importers (`DOCXImporter`, `PDFImporter`).
///
/// Both importers walk a very different source format but converge on the same
/// question: how to turn a styled run of text into Markdown without letting the
/// source text accidentally become Markdown syntax.
enum MarkdownImportFormatting {
  /// Wraps `text` in the Markdown markers for the given styles.
  ///
  /// Surrounding whitespace is moved outside the markers because `** bold **`
  /// is not emphasis. Code spans win over emphasis: backticks already imply a
  /// verbatim run, and nesting emphasis inside them would be literal.
  static func decorate(
    _ text: String,
    bold: Bool = false,
    italic: Bool = false,
    code: Bool = false,
    strikethrough: Bool = false,
    link: String? = nil
  ) -> String {
    guard !text.isEmpty else { return "" }
    let leading = String(text.prefix(while: { $0 == " " || $0 == "\t" }))
    let remainder = text.dropFirst(leading.count)
    let trailing = String(
      remainder.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
    let core = String(remainder.dropLast(trailing.count))
    guard !core.isEmpty else { return text }

    var rendered: String
    if code {
      let fence = core.contains("`") ? "``" : "`"
      let padding = core.hasPrefix("`") || core.hasSuffix("`") ? " " : ""
      rendered = fence + padding + core + padding + fence
    } else {
      rendered = escapingInline(core)
      if bold { rendered = "**" + rendered + "**" }
      if italic { rendered = "*" + rendered + "*" }
      if strikethrough { rendered = "~~" + rendered + "~~" }
    }

    if let link, !link.isEmpty {
      let needsBrackets = link.contains(" ") || link.contains("(") || link.contains(")")
      rendered = "[" + rendered + "](" + (needsBrackets ? "<" + link + ">" : link) + ")"
    }
    return leading + rendered + trailing
  }

  static func listItem(_ body: String, level: Int, marker: String) -> String {
    let indent = String(repeating: "  ", count: level)
    let continuation = "\n" + indent + String(repeating: " ", count: marker.count)
    return indent + marker + body.replacingOccurrences(of: "\n", with: continuation)
  }

  private static let inlineEscapes: Set<Character> = ["\\", "`", "*", "[", "]"]

  static func escapingInline(_ text: String) -> String {
    guard text.contains(where: { inlineEscapes.contains($0) }) else { return text }
    var output = ""
    output.reserveCapacity(text.count + 8)
    for character in text {
      if inlineEscapes.contains(character) { output.append("\\") }
      output.append(character)
    }
    return output
  }

  /// Keeps a plain paragraph from accidentally becoming a heading, quote or list.
  static func escapingBlockStart(_ text: String) -> String {
    guard let first = text.first else { return text }
    if first == "#" || first == ">" || first == "|" {
      return "\\" + text
    }
    if first == "-" || first == "+" {
      return text.dropFirst().first == " " ? "\\" + text : text
    }
    if first.isNumber {
      let digits = text.prefix(while: { $0.isNumber })
      let rest = text.dropFirst(digits.count)
      if let marker = rest.first, marker == "." || marker == ")",
        rest.dropFirst().first == " "
      {
        return String(digits) + "\\" + String(rest)
      }
    }
    return text
  }

  static func trimmingTrailingWhitespace(_ text: String) -> String {
    var result = text
    while let last = result.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
      result.removeLast()
    }
    return result
  }
}
