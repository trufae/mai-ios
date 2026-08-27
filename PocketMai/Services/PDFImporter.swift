import Foundation
import PDFKit
import UIKit
import Vision

/// Converts a PDF into Markdown, or renders its pages as images.
///
/// A PDF has no document structure to lean on the way a `.docx` does: a page is
/// a bag of positioned glyph runs, and "heading", "paragraph" and "list" are
/// things a reader infers from typography. So the text importer rebuilds that
/// structure from what PDFKit does expose — font size and weight give headings
/// and emphasis, the vertical gap between lines plus the right margin give
/// paragraph reflow, the leading glyph and indentation give lists, and link
/// annotations give inline links. Pages that carry no text layer at all (scans)
/// are read with Vision's on-device OCR.
///
/// Everything here uses Apple frameworks only: PDFKit, Vision and UIKit.
enum PDFImporter {
  enum ImportError: LocalizedError {
    case tooLarge
    case unreadableDocument
    case lockedDocument
    case emptyDocument

    var errorDescription: String? {
      switch self {
      case .tooLarge:
        "PDF attachments are limited to 25 MB."
      case .unreadableDocument:
        "The selected file could not be opened as a PDF."
      case .lockedDocument:
        "The PDF is password protected."
      case .emptyDocument:
        "No text could be extracted from the PDF."
      }
    }
  }

  static let maximumFileBytes = 25_000_000
  /// Text extraction walks every glyph, so long documents are truncated.
  static let maximumTextPages = 200
  /// OCR only runs on pages without a text layer, and only on a few of them.
  static let maximumOCRPages = 10
  static let maximumImagePages = 50
  static let defaultImagePixelSize = 2048

  /// Reads the file up front so the conversion can run off the main thread once
  /// the security-scoped access to the picked URL has been released.
  static func data(at url: URL) throws -> Data {
    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard fileSize <= maximumFileBytes else { throw ImportError.tooLarge }
    let data = try Data(contentsOf: url)
    guard data.count <= maximumFileBytes else { throw ImportError.tooLarge }
    return data
  }

  // MARK: - Text

  static func markdown(from url: URL) throws -> String {
    try markdown(from: data(at: url))
  }

  static func markdown(from data: Data) throws -> String {
    let document = try open(data)
    var lines: [Line] = []
    var ocrBudget = maximumOCRPages

    for index in 0..<min(document.pageCount, maximumTextPages) {
      guard let page = document.page(at: index) else { continue }
      var pageLines = textLines(on: page, pageIndex: index)
      if pageLines.isEmpty, ocrBudget > 0 {
        ocrBudget -= 1
        pageLines = recognizedLines(on: page, pageIndex: index)
      }
      lines.append(contentsOf: pageLines)
    }

    let text = markdown(lines: lines)
    guard !text.isEmpty else { throw ImportError.emptyDocument }
    return text
  }

  // MARK: - Images

  struct RenderedPages: Sendable {
    /// One PNG per page, in page order.
    let images: [Data]
    /// True when the document had more pages than `maximumImagePages`.
    let truncated: Bool
  }

  static func pageImages(
    from data: Data,
    maximumPixelSize: Int = defaultImagePixelSize
  ) throws -> RenderedPages {
    let document = try open(data)
    let count = min(document.pageCount, maximumImagePages)
    var images: [Data] = []
    images.reserveCapacity(count)

    for index in 0..<count {
      guard let page = document.page(at: index),
        let png = pageImage(page, maximumPixelSize: maximumPixelSize)
      else { continue }
      images.append(png)
    }

    guard !images.isEmpty else { throw ImportError.unreadableDocument }
    return RenderedPages(images: images, truncated: document.pageCount > count)
  }

  private static func pageImage(_ page: PDFPage, maximumPixelSize: Int) -> Data? {
    let bounds = page.bounds(for: .cropBox)
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    // `thumbnail(of:for:)` fits the page into the requested box and applies the
    // page rotation, so the requested box only has to carry the right aspect.
    let rotation = ((page.rotation % 360) + 360) % 360
    let size =
      rotation == 90 || rotation == 270
      ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    let scale = min(CGFloat(maximumPixelSize) / max(size.width, size.height), 4)
    let target = CGSize(
      width: max(1, (size.width * scale).rounded()),
      height: max(1, (size.height * scale).rounded()))
    return page.thumbnail(of: target, for: .cropBox).pngData()
  }

  private static func open(_ data: Data) throws -> PDFDocument {
    guard let document = PDFDocument(data: data) else { throw ImportError.unreadableDocument }
    if document.isLocked, !document.unlock(withPassword: "") { throw ImportError.lockedDocument }
    guard document.pageCount > 0 else { throw ImportError.emptyDocument }
    return document
  }
}

// MARK: - Layout model

extension PDFImporter {
  /// A rectangle in page space, flipped so that `top` grows downwards.
  struct Frame: Equatable, Sendable {
    var left: Double
    var right: Double
    var top: Double
    var bottom: Double

    init(left: Double, right: Double, top: Double, bottom: Double) {
      self.left = left
      self.right = right
      self.top = top
      self.bottom = bottom
    }

    var width: Double { max(0, right - left) }
    var height: Double { max(0, bottom - top) }
  }

  /// A stretch of text on a line that shares one style.
  struct Run: Equatable, Sendable {
    var text: String
    var size: Double
    var bold: Bool
    var italic: Bool
    var monospaced: Bool
    var link: String?

    init(
      text: String,
      size: Double = 12,
      bold: Bool = false,
      italic: Bool = false,
      monospaced: Bool = false,
      link: String? = nil
    ) {
      self.text = text
      self.size = size
      self.bold = bold
      self.italic = italic
      self.monospaced = monospaced
      self.link = link
    }

    var style: Style { Style(size: size, bold: bold, italic: italic, monospaced: monospaced) }

    struct Style: Equatable {
      var size: Double
      var bold: Bool
      var italic: Bool
      var monospaced: Bool
    }
  }

  /// One laid-out line of text, the unit the Markdown reconstruction works on.
  struct Line: Sendable {
    var runs: [Run]
    var frame: Frame
    var pageIndex: Int
    var pageWidth: Double
    var pageHeight: Double

    init(
      runs: [Run],
      frame: Frame,
      pageIndex: Int = 0,
      pageWidth: Double = 612,
      pageHeight: Double = 792
    ) {
      self.runs = runs
      self.frame = frame
      self.pageIndex = pageIndex
      self.pageWidth = pageWidth
      self.pageHeight = pageHeight
    }

    var text: String { runs.map(\.text).joined() }

    /// The font size covering most of the line's visible characters. Ties go to
    /// the larger size so a footnote marker cannot demote a heading.
    var size: Double {
      var weights: [Double: Int] = [:]
      for run in runs {
        weights[run.size, default: 0] += run.text.filter { !$0.isWhitespace }.count
      }
      let dominant = weights.max { lhs, rhs in
        lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
      }
      return dominant?.key ?? runs.first?.size ?? 12
    }

    var isBold: Bool {
      let visible = runs.filter { run in run.text.contains { !$0.isWhitespace } }
      return !visible.isEmpty && visible.allSatisfy(\.bold)
    }

    /// Drops the first `count` characters, keeping the remaining run styles.
    func droppingFirst(_ count: Int) -> Line {
      var remaining = count
      var trimmed: [Run] = []
      for run in runs {
        guard remaining > 0 else {
          trimmed.append(run)
          continue
        }
        let length = run.text.count
        if length <= remaining {
          remaining -= length
          continue
        }
        var shortened = run
        shortened.text = String(run.text.dropFirst(remaining))
        remaining = 0
        trimmed.append(shortened)
      }
      var line = self
      line.runs = trimmed
      return line
    }
  }
}

// MARK: - Markdown reconstruction

extension PDFImporter {
  /// Converts already-extracted lines into Markdown. Exposed for testing.
  static func markdown(lines rawLines: [Line]) -> String {
    let lines = prepared(rawLines)
    guard !lines.isEmpty else { return "" }
    var builder = BlockBuilder(metrics: Metrics(lines: lines))
    for line in lines { builder.append(line) }
    return builder.finish()
  }

  private static func prepared(_ lines: [Line]) -> [Line] {
    var cleaned: [Line] = []
    var monospacedCharacters = 0
    var totalCharacters = 0

    for line in lines {
      var line = line
      line.runs = normalized(line.runs)
      guard line.runs.contains(where: { run in run.text.contains { !$0.isWhitespace } })
      else { continue }
      for run in line.runs {
        let count = run.text.filter { !$0.isWhitespace }.count
        totalCharacters += count
        if run.monospaced { monospacedCharacters += count }
      }
      cleaned.append(line)
    }

    // A document typeset entirely in Courier is not one big code span.
    if totalCharacters > 0, Double(monospacedCharacters) / Double(totalCharacters) > 0.5 {
      for index in cleaned.indices {
        for runIndex in cleaned[index].runs.indices {
          cleaned[index].runs[runIndex].monospaced = false
        }
      }
    }

    return droppingRunningHeads(cleaned)
  }

  private static let ligatures: [Character: String] = [
    "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi",
    "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st",
  ]

  private static func normalized(_ runs: [Run]) -> [Run] {
    var merged: [Run] = []
    for run in runs {
      var run = run
      run.text = normalizedText(run.text)
      guard !run.text.isEmpty else { continue }
      if let last = merged.last, last.style == run.style, last.link == run.link {
        merged[merged.count - 1].text += run.text
      } else {
        merged.append(run)
      }
    }

    if var first = merged.first {
      first.text = String(first.text.drop(while: { $0 == " " || $0 == "\t" }))
      merged[0] = first
      if first.text.isEmpty { merged.removeFirst() }
    }
    if var last = merged.last {
      last.text = MarkdownImportFormatting.trimmingTrailingWhitespace(last.text)
      merged[merged.count - 1] = last
      if last.text.isEmpty { merged.removeLast() }
    }
    return merged
  }

  /// Folds the typographic spellings PDFs use back into plain text: ligatures,
  /// hard spaces, soft hyphens and the runs of spaces used for letter spacing.
  private static func normalizedText(_ text: String) -> String {
    var output = ""
    output.reserveCapacity(text.count)
    var pendingSpace = false

    for character in text {
      if character == "\u{00AD}" || character == "\u{FFFC}" { continue }
      if character.isWhitespace || character == "\u{00A0}" || character == "\u{202F}" {
        pendingSpace = true
        continue
      }
      if pendingSpace {
        output.append(" ")
        pendingSpace = false
      }
      if let expanded = ligatures[character] {
        output += expanded
      } else {
        output.append(character)
      }
    }

    if pendingSpace { output.append(" ") }
    return output
  }

  /// Drops the running head and foot: the same line, in the same band, on most
  /// of the pages. Digits are masked so "Page 3 of 20" matches "Page 4 of 20".
  private static func droppingRunningHeads(_ lines: [Line]) -> [Line] {
    let pages = Set(lines.map(\.pageIndex))
    guard pages.count >= 3 else { return lines }

    var pagesByKey: [String: Set<Int>] = [:]
    for line in lines {
      guard let key = runningHeadKey(line) else { continue }
      pagesByKey[key, default: []].insert(line.pageIndex)
    }

    let threshold = max(3, Int((Double(pages.count) * 0.5).rounded()))
    let repeated = Set(pagesByKey.filter { $0.value.count >= threshold }.keys)
    guard !repeated.isEmpty else { return lines }

    return lines.filter { line in
      guard let key = runningHeadKey(line) else { return true }
      return !repeated.contains(key)
    }
  }

  private static func runningHeadKey(_ line: Line) -> String? {
    guard line.pageHeight > 0 else { return nil }
    let band: String
    if line.frame.bottom <= line.pageHeight * 0.09 {
      band = "head"
    } else if line.frame.top >= line.pageHeight * 0.91 {
      band = "foot"
    } else {
      return nil
    }

    let masked = String(line.text.lowercased().map { $0.isNumber ? "#" : $0 })
    let collapsed = masked.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !collapsed.isEmpty, collapsed.count <= 120 else { return nil }
    return band + ":" + collapsed
  }

  /// Document-wide typography, used to tell headings from body text.
  private struct Metrics {
    private let headingSizes: [Double]
    private let rightEdgeByPage: [Int: Double]

    init(lines: [Line]) {
      var weights: [Double: Int] = [:]
      var rightEdges: [Int: Double] = [:]

      for line in lines {
        let size = Metrics.bucket(line.size)
        weights[size, default: 0] += line.text.filter { !$0.isWhitespace }.count
        rightEdges[line.pageIndex] = max(rightEdges[line.pageIndex] ?? 0, line.frame.right)
      }

      // Ties go to the smaller size: body text is smaller than its headings.
      let body =
        weights.max { lhs, rhs in
          lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key ?? 12

      rightEdgeByPage = rightEdges
      headingSizes = Array(
        Set(lines.map { Metrics.bucket($0.size) })
          .filter { $0 > body + 0.5 }
          .sorted(by: >)
          .prefix(5))
    }

    /// Sizes are compared in half-point buckets; PDF font sizes are rarely round.
    static func bucket(_ size: Double) -> Double { (size * 2).rounded() / 2 }

    func headingLevel(for size: Double) -> Int? {
      let bucketed = Metrics.bucket(size)
      guard let index = headingSizes.firstIndex(where: { abs($0 - bucketed) < 0.01 }) else {
        return nil
      }
      return min(6, index + 1)
    }

    /// Level used for a bold line that is not any bigger than the body text.
    var boldHeadingLevel: Int { min(6, headingSizes.count + 1) }

    func rightEdge(page: Int) -> Double { rightEdgeByPage[page] ?? 0 }
  }

  /// A bullet or number opening a line.
  private struct ListMarker {
    let ordered: Bool
    /// Characters to drop from the line, marker and following spaces included.
    let length: Int

    private static let bullets: Set<Character> = [
      "\u{2022}", "\u{2023}", "\u{25E6}", "\u{25AA}", "\u{25AB}", "\u{25CF}", "\u{25CB}",
      "\u{2043}", "\u{00B7}", "\u{2219}", "\u{25A0}", "\u{25A1}", "\u{2212}", "\u{2013}",
      "\u{2014}", "-", "*", "+", "\u{F0B7}",
    ]

    static func parse(_ text: String) -> ListMarker? {
      guard let first = text.first else { return nil }

      if bullets.contains(first) {
        let rest = text.dropFirst()
        let spaces = rest.prefix(while: { $0 == " " || $0 == "\t" }).count
        guard spaces > 0 else { return nil }
        guard rest.dropFirst(spaces).contains(where: { !$0.isWhitespace }) else { return nil }
        return ListMarker(ordered: false, length: 1 + spaces)
      }

      guard first.isNumber else { return nil }
      let digits = text.prefix(while: \.isNumber)
      guard digits.count <= 3 else { return nil }
      let rest = text.dropFirst(digits.count)
      guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
      let spaces = rest.dropFirst().prefix(while: { $0 == " " || $0 == "\t" }).count
      guard spaces > 0 else { return nil }
      guard rest.dropFirst(1 + spaces).contains(where: { !$0.isWhitespace }) else { return nil }
      return ListMarker(ordered: true, length: digits.count + 1 + spaces)
    }
  }

  /// Walks the lines in reading order and groups them into Markdown blocks.
  private struct BlockBuilder {
    private enum Kind {
      case paragraph
      case heading(Int)
      case list(ordered: Bool, level: Int)
    }

    private enum Join {
      /// The previous line ended on a hyphenated word split.
      case hyphen
      /// The previous line wrapped: reflow into one paragraph.
      case space
      /// The previous line ended deliberately short: keep the break.
      case lineBreak
    }

    private struct Block {
      var kind: Kind
      var text: String
      var line: Line
      var left: Double
      var lineCount: Int
      var allBold: Bool
    }

    private let metrics: Metrics
    private var rendered: [(text: String, isListItem: Bool)] = []
    private var current: Block?
    /// Left edges of the list markers currently open, one per nesting level.
    private var listIndents: [Double] = []

    init(metrics: Metrics) {
      self.metrics = metrics
    }

    mutating func append(_ line: Line) {
      let marker = ListMarker.parse(line.text)
      if let block = current, !startsNewBlock(line, marker: marker, after: block) {
        current = extended(block, with: line)
        return
      }
      flush()
      current = begin(line, marker: marker)
    }

    mutating func finish() -> String {
      flush()
      var output = ""
      for (index, block) in rendered.enumerated() where !block.text.isEmpty {
        if !output.isEmpty {
          let tight = block.isListItem && index > 0 && rendered[index - 1].isListItem
          output += tight ? "\n" : "\n\n"
        }
        output += block.text
      }
      return output
    }

    // MARK: Block boundaries

    private func startsNewBlock(_ line: Line, marker: ListMarker?, after block: Block) -> Bool {
      if marker != nil { return true }
      if Metrics.bucket(line.size) != Metrics.bucket(block.line.size) { return true }
      if line.isBold != block.line.isBold { return true }

      if line.pageIndex != block.line.pageIndex {
        // Only a paragraph that was cut mid-sentence runs over the page break.
        if case .paragraph = block.kind {
          return PDFImporter.endsSentence(block.line.text)
        }
        return true
      }

      let height = max(block.line.frame.height, line.frame.height)
      let gap = line.frame.top - block.line.frame.bottom
      if height > 0, gap > height * 0.75 { return true }
      // Moving back up the page means a new column, not a wrapped line.
      if height > 0, gap < -height * 0.5 { return true }

      switch block.kind {
      case .list:
        // Text keeps flowing while it stays indented past the marker.
        return line.frame.left < block.left + max(2, line.size * 0.5)
      case .heading:
        return false
      case .paragraph:
        // A fresh indent opens a new paragraph even without extra leading.
        return line.frame.left > block.left + max(6, line.size * 0.6)
      }
    }

    private func joinStyle(previous: Line, next: Line) -> Join {
      let text = previous.text
      if let last = text.last, last == "-" || last == "\u{2010}",
        let first = next.text.first, first.isLowercase
      {
        return .hyphen
      }

      let nextWord = next.text.prefix(while: { !$0.isWhitespace })
      if reachesRightEdge(previous, nextWord: String(nextWord)) { return .space }
      if !PDFImporter.endsSentence(text), next.text.first?.isLowercase == true { return .space }
      return .lineBreak
    }

    /// True when the next word would not have fitted on the previous line, which
    /// is what separates a wrapped line from one that ended on purpose.
    private func reachesRightEdge(_ line: Line, nextWord: String) -> Bool {
      let edge = max(metrics.rightEdge(page: line.pageIndex), line.pageWidth * 0.72)
      guard edge > 0, line.frame.width > 0 else { return true }
      let characterWidth = line.frame.width / Double(max(line.text.count, 1))
      let needed = Double(nextWord.count + 1) * characterWidth
      return line.frame.right + needed > edge - characterWidth
    }

    // MARK: Block building

    private mutating func begin(_ line: Line, marker: ListMarker?) -> Block {
      if let marker {
        let body = line.droppingFirst(marker.length)
        return Block(
          kind: .list(ordered: marker.ordered, level: listLevel(at: line.frame.left)),
          text: PDFImporter.inlineMarkdown(body),
          line: line,
          left: line.frame.left,
          lineCount: 1,
          allBold: line.isBold)
      }

      listIndents.removeAll()
      let kind: Kind
      let text: String
      if let level = metrics.headingLevel(for: line.size) {
        kind = .heading(level)
        text = PDFImporter.inlineMarkdown(line, stripEmphasis: true)
      } else {
        kind = .paragraph
        text = PDFImporter.inlineMarkdown(line)
      }
      return Block(
        kind: kind,
        text: text,
        line: line,
        left: line.frame.left,
        lineCount: 1,
        allBold: line.isBold)
    }

    private func extended(_ block: Block, with line: Line) -> Block {
      var block = block
      var isHeading = false
      if case .heading = block.kind { isHeading = true }
      let text = PDFImporter.inlineMarkdown(line, stripEmphasis: isHeading)

      switch joinStyle(previous: block.line, next: line) {
      case .hyphen:
        if block.text.hasSuffix("-") { block.text.removeLast() }
        block.text += text
      case .space:
        block.text += " " + text
      case .lineBreak:
        block.text += "  \n" + text
      }

      block.line = line
      block.lineCount += 1
      block.allBold = block.allBold && line.isBold
      return block
    }

    /// Nesting is read from where the markers sit: further right is deeper.
    private mutating func listLevel(at left: Double) -> Int {
      while let last = listIndents.last, left < last - 2 { listIndents.removeLast() }
      if let last = listIndents.last {
        if left > last + 6 { listIndents.append(left) }
      } else {
        listIndents.append(left)
      }
      return min(listIndents.count - 1, 8)
    }

    private mutating func flush() {
      guard let block = current else { return }
      current = nil

      var kind = block.kind
      var text = MarkdownImportFormatting.trimmingTrailingWhitespace(block.text)
      guard !text.isEmpty else { return }

      // A short bold line on its own is a heading even at body size.
      if case .paragraph = kind, block.lineCount == 1, block.allBold,
        block.line.text.count <= 80, !PDFImporter.endsSentence(block.line.text)
      {
        kind = .heading(metrics.boldHeadingLevel)
        text = PDFImporter.inlineMarkdown(block.line, stripEmphasis: true)
      }

      switch kind {
      case .heading(let level):
        let hashes = String(repeating: "#", count: min(max(level, 1), 6))
        let single =
          text
          .replacingOccurrences(of: "  \n", with: " ")
          .replacingOccurrences(of: "\n", with: " ")
        rendered.append((hashes + " " + single, false))
      case .list(let ordered, let level):
        let marker = ordered ? "1. " : "- "
        let item = MarkdownImportFormatting.listItem(text, level: level, marker: marker)
        rendered.append((item, true))
      case .paragraph:
        rendered.append((MarkdownImportFormatting.escapingBlockStart(text), false))
      }
    }
  }

  private static func inlineMarkdown(_ line: Line, stripEmphasis: Bool = false) -> String {
    var output = ""
    for run in line.runs {
      output += MarkdownImportFormatting.decorate(
        run.text,
        bold: stripEmphasis ? false : run.bold,
        italic: stripEmphasis ? false : run.italic,
        code: stripEmphasis ? false : run.monospaced,
        link: run.link)
    }
    return MarkdownImportFormatting.trimmingTrailingWhitespace(output)
  }

  private static func endsSentence(_ text: String) -> Bool {
    var trimmed = text[...]
    while let last = trimmed.last, "\"')]}\u{00BB}\u{201D}\u{2019} ".contains(last) {
      trimmed = trimmed.dropLast()
    }
    guard let last = trimmed.last else { return false }
    return ".!?:;".contains(last)
  }
}

// MARK: - PDFKit extraction

extension PDFImporter {
  private struct LinkTarget {
    let text: String
    let url: String
    let frame: Frame
  }

  private static func textLines(on page: PDFPage, pageIndex: Int) -> [Line] {
    guard let attributed = page.attributedString, attributed.length > 0 else { return [] }
    let bounds = page.bounds(for: .mediaBox)
    let pageWidth = Double(bounds.width)
    let pageHeight = Double(bounds.height)
    guard pageWidth > 0, pageHeight > 0 else { return [] }

    let contents = attributed.string as NSString
    var ranges: [NSRange] = []
    contents.enumerateSubstrings(
      in: NSRange(location: 0, length: contents.length),
      options: [.byLines, .substringNotRequired]
    ) { _, range, _, _ in
      ranges.append(range)
    }

    // `characterBounds(at:)` indexes the page's own string; keep every sample
    // inside it even if PDFKit disagrees with the attributed string's length.
    let limit = min(page.string?.utf16.count ?? 0, contents.length)
    let links = linkTargets(on: page, bounds: bounds)
    var lines: [Line] = []
    lines.reserveCapacity(ranges.count)
    var fallbackTop = 0.0

    for range in ranges {
      guard range.length > 0 else { continue }
      let text = contents.substring(with: range)
      guard text.contains(where: { !$0.isWhitespace }) else { continue }

      var runs: [Run] = []
      attributed.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
        let style = fontStyle(for: value as? UIFont)
        runs.append(
          Run(
            text: contents.substring(with: subrange),
            size: style.size,
            bold: style.bold,
            italic: style.italic,
            monospaced: style.monospaced))
      }
      if runs.isEmpty { runs = [Run(text: text)] }

      let size = runs.first?.size ?? 12
      let frame = self.frame(
        for: range, on: page, bounds: bounds, limit: limit, fallbackTop: fallbackTop, size: size)
      fallbackTop = frame.bottom + size * 0.3

      let line = Line(
        runs: runs,
        frame: frame,
        pageIndex: pageIndex,
        pageWidth: pageWidth,
        pageHeight: pageHeight)
      lines.append(applying(links: links, to: line))
    }
    return lines
  }

  /// Unions the bounds of a sample of the line's characters. PDFKit reports them
  /// one glyph at a time, so long lines are sampled rather than walked.
  private static func frame(
    for range: NSRange,
    on page: PDFPage,
    bounds: CGRect,
    limit: Int,
    fallbackTop: Double,
    size: Double
  ) -> Frame {
    var indexes: [Int] = []
    let step = max(1, range.length / 8)
    var index = range.location
    while index < range.location + range.length {
      indexes.append(index)
      index += step
    }
    indexes.append(range.location + range.length - 1)

    var union: CGRect?
    for index in indexes where index >= 0 && index < limit {
      let glyph = page.characterBounds(at: index)
      guard !glyph.isNull, glyph.height > 0, glyph.width.isFinite, glyph.height.isFinite else {
        continue
      }
      union = union.map { $0.union(glyph) } ?? glyph
    }

    guard let union, union.height > 0 else {
      return Frame(
        left: 0, right: Double(bounds.width), top: fallbackTop, bottom: fallbackTop + size * 1.2)
    }

    let top = Double(bounds.maxY - union.maxY)
    return Frame(
      left: Double(union.minX - bounds.minX),
      right: Double(union.maxX - bounds.minX),
      top: top,
      bottom: top + Double(union.height))
  }

  private static func linkTargets(on page: PDFPage, bounds: CGRect) -> [LinkTarget] {
    var targets: [LinkTarget] = []
    for annotation in page.annotations {
      guard let action = annotation.action as? PDFActionURL, let url = action.url else { continue }
      let text =
        page.selection(for: annotation.bounds)?.string?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !text.isEmpty else { continue }
      let top = Double(bounds.maxY - annotation.bounds.maxY)
      targets.append(
        LinkTarget(
          text: normalizedText(text),
          url: url.absoluteString,
          frame: Frame(
            left: Double(annotation.bounds.minX - bounds.minX),
            right: Double(annotation.bounds.maxX - bounds.minX),
            top: top,
            bottom: top + Double(annotation.bounds.height))))
    }
    return targets
  }

  private static func applying(links: [LinkTarget], to line: Line) -> Line {
    guard !links.isEmpty else { return line }
    var line = line

    for link in links {
      let overlap =
        min(line.frame.bottom, link.frame.bottom) - max(line.frame.top, link.frame.top)
      guard overlap > min(line.frame.height, link.frame.height) * 0.4 else { continue }
      guard min(line.frame.right, link.frame.right) > max(line.frame.left, link.frame.left) else {
        continue
      }
      let text = line.text
      guard let range = text.range(of: link.text) else { continue }
      line.runs = marking(
        line.runs,
        url: link.url,
        from: text.distance(from: text.startIndex, to: range.lowerBound),
        length: link.text.count)
    }
    return line
  }

  private static func marking(
    _ runs: [Run], url: String, from start: Int, length: Int
  ) -> [Run] {
    guard length > 0 else { return runs }
    var output: [Run] = []
    var cursor = 0
    let end = start + length

    for run in runs {
      let characters = Array(run.text)
      let runStart = cursor
      cursor += characters.count
      guard runStart < end, cursor > start else {
        output.append(run)
        continue
      }

      let localStart = max(0, start - runStart)
      let localEnd = min(characters.count, end - runStart)
      guard localStart < localEnd else {
        output.append(run)
        continue
      }

      if localStart > 0 {
        var head = run
        head.text = String(characters[0..<localStart])
        output.append(head)
      }
      var linked = run
      linked.text = String(characters[localStart..<localEnd])
      linked.link = url
      output.append(linked)
      if localEnd < characters.count {
        var tail = run
        tail.text = String(characters[localEnd..<characters.count])
        output.append(tail)
      }
    }
    return output
  }

  /// PDF fonts rarely carry usable symbolic traits, so the name is the fallback.
  private static func fontStyle(for font: UIFont?) -> (
    size: Double, bold: Bool, italic: Bool, monospaced: Bool
  ) {
    guard let font else { return (12, false, false, false) }
    let traits = font.fontDescriptor.symbolicTraits
    let name = font.fontName.lowercased()
    let bold =
      traits.contains(.traitBold) || name.contains("bold") || name.contains("semibold")
      || name.contains("black") || name.contains("heavy")
    let italic =
      traits.contains(.traitItalic) || name.contains("italic") || name.contains("oblique")
    let monospaced =
      traits.contains(.traitMonoSpace) || name.contains("mono") || name.contains("courier")
      || name.contains("consol")
    return (Double(font.pointSize), bold, italic, monospaced)
  }
}

// MARK: - OCR

extension PDFImporter {
  /// Reads a page that carries no text layer with Vision's on-device recogniser.
  private static func recognizedLines(on page: PDFPage, pageIndex: Int) -> [Line] {
    let bounds = page.bounds(for: .cropBox)
    let pageWidth = Double(bounds.width)
    let pageHeight = Double(bounds.height)
    guard pageWidth > 0, pageHeight > 0 else { return [] }

    let scale = min(2000 / max(bounds.width, bounds.height), 4)
    let target = CGSize(
      width: max(1, (bounds.width * scale).rounded()),
      height: max(1, (bounds.height * scale).rounded()))
    guard let image = page.thumbnail(of: target, for: .cropBox).cgImage else { return [] }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
      return []
    }
    guard let observations = request.results else { return [] }

    var lines: [Line] = []
    for observation in observations {
      guard let candidate = observation.topCandidates(1).first else { continue }
      guard candidate.string.contains(where: { !$0.isWhitespace }) else { continue }

      let box = observation.boundingBox
      let frame = Frame(
        left: Double(box.minX) * pageWidth,
        right: Double(box.maxX) * pageWidth,
        top: Double(1 - box.maxY) * pageHeight,
        bottom: Double(1 - box.minY) * pageHeight)
      // Recognised heights vary line by line, so they are quantised before they
      // are used to tell headings from body text.
      let size = max(2, (frame.height * 0.8 / 2).rounded() * 2)
      lines.append(
        Line(
          runs: [Run(text: candidate.string, size: size)],
          frame: frame,
          pageIndex: pageIndex,
          pageWidth: pageWidth,
          pageHeight: pageHeight))
    }

    lines.sort { lhs, rhs in
      let tolerance = min(lhs.frame.height, rhs.frame.height) * 0.5
      if abs(lhs.frame.top - rhs.frame.top) > tolerance {
        return lhs.frame.top < rhs.frame.top
      }
      return lhs.frame.left < rhs.frame.left
    }
    return lines
  }
}
