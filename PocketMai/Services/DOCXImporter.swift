import Foundation

/// Converts a Word document (.docx) into Markdown so it can be attached as a text file.
///
/// A .docx file is a zip container; the body lives in `word/document.xml` as
/// WordprocessingML. Only the parts that map cleanly onto Markdown are kept:
/// headings, emphasis, inline code, hyperlinks, lists and tables. Everything
/// else (images, fields, tracked deletions, revision metadata) is dropped.
enum DOCXImporter {
  enum ImportError: LocalizedError {
    case tooLarge
    case unreadableArchive
    case missingDocument
    case emptyDocument

    var errorDescription: String? {
      switch self {
      case .tooLarge:
        "Word attachments are limited to 25 MB."
      case .unreadableArchive:
        "The selected file could not be opened as a Word document."
      case .missingDocument:
        "The Word document is missing its main body."
      case .emptyDocument:
        "The Word document does not contain any text."
      }
    }
  }

  static let maximumArchiveBytes = 25_000_000

  static func markdown(from url: URL) throws -> String {
    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard fileSize <= maximumArchiveBytes else { throw ImportError.tooLarge }

    // MiniZip (see WebXDCService) reads both stored and deflated zip entries.
    let entries: [MiniZip.Entry]
    do {
      entries = try MiniZip.read(from: url)
    } catch {
      throw ImportError.unreadableArchive
    }

    var parts: [String: Data] = [:]
    for entry in entries {
      parts[entry.path] = entry.data
    }
    return try markdown(parts: parts)
  }

  /// Converts already-extracted document parts. Exposed for testing.
  static func markdown(parts: [String: Data]) throws -> String {
    guard let document = parts["word/document.xml"] else { throw ImportError.missingDocument }
    let numbering = NumberingIndex(xml: parts["word/numbering.xml"])
    let relationships = RelationshipIndex(xml: parts["word/_rels/document.xml.rels"])
    let parser = DocumentParser(numbering: numbering, relationships: relationships)
    guard let markdown = parser.parse(document) else { throw ImportError.unreadableArchive }
    guard !markdown.isEmpty else { throw ImportError.emptyDocument }
    return markdown
  }
}

// MARK: - Shared XML helpers

private func localName(_ name: String) -> String {
  guard let colon = name.lastIndex(of: ":") else { return name }
  return String(name[name.index(after: colon)...])
}

private func attributeValue(_ attributes: [String: String], _ name: String) -> String? {
  if let direct = attributes[name] { return direct }
  for (key, value) in attributes where localName(key) == name { return value }
  return nil
}

/// WordprocessingML toggles default to on when the value attribute is absent.
private func isToggleOn(_ attributes: [String: String]) -> Bool {
  guard let value = attributeValue(attributes, "val")?.lowercased() else { return true }
  return value != "0" && value != "false" && value != "off" && value != "none"
}

// MARK: - Numbering

/// Maps a paragraph's `w:numId` and `w:ilvl` onto "ordered" or "bulleted".
private struct NumberingIndex {
  private var orderedLevelsByNumberID: [String: [Int: Bool]] = [:]

  init(xml: Data?) {
    guard let xml else { return }
    let delegate = NumberingDelegate()
    let parser = XMLParser(data: xml)
    parser.delegate = delegate
    guard parser.parse() else { return }
    for (numberID, abstractID) in delegate.abstractIDsByNumberID {
      orderedLevelsByNumberID[numberID] = delegate.orderedLevelsByAbstractID[abstractID] ?? [:]
    }
  }

  func isOrdered(numberID: String, level: Int) -> Bool {
    guard let levels = orderedLevelsByNumberID[numberID] else { return false }
    return levels[level] ?? levels[0] ?? false
  }
}

private final class NumberingDelegate: NSObject, XMLParserDelegate {
  private(set) var abstractIDsByNumberID: [String: String] = [:]
  private(set) var orderedLevelsByAbstractID: [String: [Int: Bool]] = [:]

  private var currentAbstractID: String?
  private var currentNumberID: String?
  private var currentLevel: Int?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes: [String: String] = [:]
  ) {
    switch localName(elementName) {
    case "abstractNum":
      currentAbstractID = attributeValue(attributes, "abstractNumId")
    case "num":
      currentNumberID = attributeValue(attributes, "numId")
    case "abstractNumId":
      if let numberID = currentNumberID, let value = attributeValue(attributes, "val") {
        abstractIDsByNumberID[numberID] = value
      }
    case "lvl":
      currentLevel = attributeValue(attributes, "ilvl").flatMap { Int($0) }
    case "numFmt":
      guard let abstractID = currentAbstractID, let level = currentLevel,
        let format = attributeValue(attributes, "val")?.lowercased()
      else { break }
      orderedLevelsByAbstractID[abstractID, default: [:]][level] =
        format != "bullet" && format != "none"
    default:
      break
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?
  ) {
    switch localName(elementName) {
    case "abstractNum":
      currentAbstractID = nil
    case "num":
      currentNumberID = nil
    case "lvl":
      currentLevel = nil
    default:
      break
    }
  }
}

// MARK: - Relationships

/// Resolves `w:hyperlink r:id` references to external URLs.
private struct RelationshipIndex {
  private var targetsByID: [String: String] = [:]

  init(xml: Data?) {
    guard let xml else { return }
    let delegate = RelationshipDelegate()
    let parser = XMLParser(data: xml)
    parser.delegate = delegate
    guard parser.parse() else { return }
    targetsByID = delegate.targetsByID
  }

  func target(forID id: String?) -> String? {
    guard let id else { return nil }
    return targetsByID[id]
  }
}

private final class RelationshipDelegate: NSObject, XMLParserDelegate {
  private(set) var targetsByID: [String: String] = [:]

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes: [String: String] = [:]
  ) {
    guard localName(elementName) == "Relationship",
      let id = attributeValue(attributes, "Id"),
      let target = attributeValue(attributes, "Target")
    else { return }
    let isExternal =
      attributeValue(attributes, "TargetMode")?.lowercased() == "external"
      || target.contains("://")
      || target.lowercased().hasPrefix("mailto:")
    guard isExternal else { return }
    targetsByID[id] = target
  }
}

// MARK: - Document body

private final class DocumentParser: NSObject, XMLParserDelegate {
  private struct RunStyle: Equatable {
    var bold = false
    var italic = false
    var strikethrough = false
    var code = false
    var link: String?
  }

  private enum Fragment {
    case text(String, RunStyle)
    case lineBreak
  }

  private struct Block {
    var text: String
    var isListItem: Bool
  }

  private struct TableState {
    var rows: [[String]] = []
    var currentRow: [String] = []
  }

  private let numbering: NumberingIndex
  private let relationships: RelationshipIndex

  /// Stack of block sinks: index 0 is the document body, deeper entries are table cells.
  private var blockStack: [[Block]] = [[]]
  private var tableStack: [TableState] = []
  private var linkStack: [String?] = []

  private var fragments: [Fragment] = []
  private var runStyle = RunStyle()
  private var isInsideRun = false
  private var isInsideParagraphProperties = false
  private var paragraphStyle: String?
  private var listLevel: Int?
  private var listNumberID: String?
  private var isCapturingText = false
  private var capturedText = ""

  init(numbering: NumberingIndex, relationships: RelationshipIndex) {
    self.numbering = numbering
    self.relationships = relationships
  }

  func parse(_ data: Data) -> String? {
    let parser = XMLParser(data: data)
    parser.delegate = self
    let parsed = parser.parse()
    let rendered = Self.render(blockStack.first ?? [])
    guard parsed || !rendered.isEmpty else { return nil }
    return rendered
  }

  // MARK: XMLParserDelegate

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes: [String: String] = [:]
  ) {
    switch localName(elementName) {
    case "p":
      beginParagraph()
    case "pPr":
      isInsideParagraphProperties = true
    case "pStyle":
      if isInsideParagraphProperties { paragraphStyle = attributeValue(attributes, "val") }
    case "ilvl":
      if isInsideParagraphProperties {
        listLevel = attributeValue(attributes, "val").flatMap { Int($0) }
      }
    case "numId":
      if isInsideParagraphProperties { listNumberID = attributeValue(attributes, "val") }
    case "hyperlink":
      linkStack.append(relationships.target(forID: attributeValue(attributes, "id")))
    case "r":
      isInsideRun = true
      runStyle = RunStyle(link: linkStack.last ?? nil)
    case "b":
      if isInsideRun { runStyle.bold = isToggleOn(attributes) }
    case "i":
      if isInsideRun { runStyle.italic = isToggleOn(attributes) }
    case "strike", "dstrike":
      if isInsideRun { runStyle.strikethrough = isToggleOn(attributes) }
    case "rStyle":
      if isInsideRun, let style = attributeValue(attributes, "val")?.lowercased(),
        style.contains("code") || style.contains("htmlcode") || style.contains("verbatim")
      {
        runStyle.code = true
      }
    case "t":
      isCapturingText = true
      capturedText = ""
    case "br", "cr":
      if isInsideRun { fragments.append(.lineBreak) }
    case "tab":
      if isInsideRun { fragments.append(.text(" ", runStyle)) }
    case "tbl":
      tableStack.append(TableState())
    case "tr":
      if !tableStack.isEmpty { tableStack[tableStack.count - 1].currentRow = [] }
    case "tc":
      blockStack.append([])
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard isCapturingText else { return }
    capturedText += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?
  ) {
    switch localName(elementName) {
    case "p":
      endParagraph()
    case "pPr":
      isInsideParagraphProperties = false
    case "t":
      if isCapturingText, !capturedText.isEmpty {
        fragments.append(.text(capturedText, runStyle))
      }
      isCapturingText = false
      capturedText = ""
    case "r":
      isInsideRun = false
      runStyle = RunStyle()
    case "hyperlink":
      if !linkStack.isEmpty { linkStack.removeLast() }
    case "tc":
      endCell()
    case "tr":
      guard !tableStack.isEmpty else { break }
      let row = tableStack[tableStack.count - 1].currentRow
      tableStack[tableStack.count - 1].currentRow = []
      if !row.isEmpty { tableStack[tableStack.count - 1].rows.append(row) }
    case "tbl":
      endTable()
    default:
      break
    }
  }

  // MARK: Blocks

  private func beginParagraph() {
    fragments = []
    paragraphStyle = nil
    listLevel = nil
    listNumberID = nil
  }

  private func endParagraph() {
    let body = Self.trimmingTrailingWhitespace(Self.render(fragments: fragments))
    fragments = []
    guard !body.isEmpty else { return }

    let style =
      paragraphStyle?
      .lowercased()
      .replacingOccurrences(of: "_20_", with: "")
      .replacingOccurrences(of: " ", with: "")
    var text = body
    var isListItem = false

    if let numberID = listNumberID, numberID != "0" {
      let level = min(max(listLevel ?? 0, 0), 8)
      let marker = numbering.isOrdered(numberID: numberID, level: level) ? "1. " : "- "
      text = Self.listItem(body, level: level, marker: marker)
      isListItem = true
    } else if style == "listparagraph" {
      let level = min(max(listLevel ?? 0, 0), 8)
      text = Self.listItem(body, level: level, marker: "- ")
      isListItem = true
    } else if let level = Self.headingLevel(for: style) {
      text = String(repeating: "#", count: level) + " " + body
    } else if let style, Self.isQuoteStyle(style) {
      text = "> " + body.replacingOccurrences(of: "\n", with: "\n> ")
    } else {
      text = Self.escapingBlockStart(body)
    }

    blockStack[blockStack.count - 1].append(Block(text: text, isListItem: isListItem))
  }

  private func endCell() {
    guard blockStack.count > 1 else { return }
    let cell = Self.tableCellText(Self.render(blockStack.removeLast()))
    guard !tableStack.isEmpty else { return }
    tableStack[tableStack.count - 1].currentRow.append(cell)
  }

  private func endTable() {
    guard !tableStack.isEmpty else { return }
    var table = tableStack.removeLast()
    if !table.currentRow.isEmpty {
      table.rows.append(table.currentRow)
    }
    let rendered = Self.render(table: table)
    guard !rendered.isEmpty else { return }
    blockStack[blockStack.count - 1].append(Block(text: rendered, isListItem: false))
  }

  // MARK: Rendering

  private static func render(_ blocks: [Block]) -> String {
    var output = ""
    var previousWasListItem = false
    for block in blocks where !block.text.isEmpty {
      if !output.isEmpty {
        output += block.isListItem && previousWasListItem ? "\n" : "\n\n"
      }
      output += block.text
      previousWasListItem = block.isListItem
    }
    return output
  }

  private static func render(fragments: [Fragment]) -> String {
    var merged: [Fragment] = []
    for fragment in fragments {
      if case .text(let text, let style) = fragment, let last = merged.last,
        case .text(let previous, let previousStyle) = last, previousStyle == style
      {
        merged[merged.count - 1] = .text(previous + text, style)
      } else {
        merged.append(fragment)
      }
    }

    var output = ""
    for fragment in merged {
      switch fragment {
      case .lineBreak:
        output += "  \n"
      case .text(let text, let style):
        output += decorate(text, style: style)
      }
    }
    return output
  }

  private static func decorate(_ text: String, style: RunStyle) -> String {
    guard !text.isEmpty else { return "" }
    let leading = String(text.prefix(while: { $0 == " " || $0 == "\t" }))
    let remainder = text.dropFirst(leading.count)
    let trailing = String(remainder.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
    let core = String(remainder.dropLast(trailing.count))
    guard !core.isEmpty else { return text }

    var rendered: String
    if style.code {
      let fence = core.contains("`") ? "``" : "`"
      let padding = core.hasPrefix("`") || core.hasSuffix("`") ? " " : ""
      rendered = fence + padding + core + padding + fence
    } else {
      rendered = escapingInline(core)
      if style.bold { rendered = "**" + rendered + "**" }
      if style.italic { rendered = "*" + rendered + "*" }
      if style.strikethrough { rendered = "~~" + rendered + "~~" }
    }

    if let link = style.link, !link.isEmpty {
      let needsBrackets = link.contains(" ") || link.contains("(") || link.contains(")")
      rendered = "[" + rendered + "](" + (needsBrackets ? "<" + link + ">" : link) + ")"
    }
    return leading + rendered + trailing
  }

  private static func render(table: TableState) -> String {
    let rows = table.rows.filter { !$0.isEmpty }
    guard let columnCount = rows.map(\.count).max(), columnCount > 0 else { return "" }

    var lines: [String] = []
    for (index, row) in rows.enumerated() {
      var cells = row.map { $0.isEmpty ? " " : $0 }
      cells.append(contentsOf: Array(repeating: " ", count: columnCount - cells.count))
      lines.append("| " + cells.joined(separator: " | ") + " |")
      if index == 0 {
        let separator = Array(repeating: "---", count: columnCount).joined(separator: " | ")
        lines.append("| " + separator + " |")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func tableCellText(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|") }
      .filter { !$0.isEmpty }
      .joined(separator: "<br>")
  }

  private static func listItem(_ body: String, level: Int, marker: String) -> String {
    let indent = String(repeating: "  ", count: level)
    let continuation = "\n" + indent + String(repeating: " ", count: marker.count)
    return indent + marker + body.replacingOccurrences(of: "\n", with: continuation)
  }

  private static func isQuoteStyle(_ style: String) -> Bool {
    style == "quote" || style == "intensequote" || style == "blockquote"
      || style == "quotations" || style == "blocktext"
  }

  private static func headingLevel(for style: String?) -> Int? {
    guard let style else { return nil }
    if style == "title" { return 1 }
    if style == "subtitle" { return 2 }
    guard style.hasPrefix("heading") else { return nil }
    guard let level = Int(style.dropFirst("heading".count)) else { return nil }
    return min(max(level, 1), 6)
  }

  private static let inlineEscapes: Set<Character> = ["\\", "`", "*", "[", "]"]

  private static func escapingInline(_ text: String) -> String {
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
  private static func escapingBlockStart(_ text: String) -> String {
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

  private static func trimmingTrailingWhitespace(_ text: String) -> String {
    var result = text
    while let last = result.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
      result.removeLast()
    }
    return result
  }
}
