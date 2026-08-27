import XCTest

@testable import PocketMai

/// The PDFKit extraction is exercised through the layout model: these tests feed
/// `PDFImporter` the same laid-out lines a page would produce and check the
/// Markdown that comes back out.
final class PDFImporterTests: XCTestCase {
  private struct Page {
    static let width = 612.0
    static let height = 792.0
    static let left = 72.0
    static let right = 540.0

    var index: Int
    var cursor = 72.0

    init(index: Int = 0) {
      self.index = index
    }

    /// Appends a line. `full` lines run to the right margin, which is what makes
    /// the importer treat the following line as a wrap rather than a break.
    mutating func line(
      _ runs: [PDFImporter.Run],
      size: Double = 12,
      indent: Double = 0,
      gap: Double = 0,
      full: Bool = true,
      top: Double? = nil
    ) -> PDFImporter.Line {
      let text = runs.map(\.text).joined()
      let left = Page.left + indent
      let width = full ? Page.right - left : Double(text.count) * size * 0.5
      let start = top ?? (cursor + gap)
      cursor = start + size * 1.2
      return PDFImporter.Line(
        runs: runs,
        frame: PDFImporter.Frame(
          left: left,
          right: min(left + width, Page.right),
          top: start,
          bottom: start + size * 1.2),
        pageIndex: index,
        pageWidth: Page.width,
        pageHeight: Page.height)
    }

    mutating func line(
      _ text: String,
      size: Double = 12,
      bold: Bool = false,
      italic: Bool = false,
      indent: Double = 0,
      gap: Double = 0,
      full: Bool = true,
      top: Double? = nil
    ) -> PDFImporter.Line {
      line(
        [PDFImporter.Run(text: text, size: size, bold: bold, italic: italic)],
        size: size, indent: indent, gap: gap, full: full, top: top)
    }
  }

  func testHeadingsAndParagraphReflow() {
    var page = Page()
    let lines = [
      page.line("Quarterly Report", size: 24, full: false),
      page.line("Overview", size: 16, gap: 12, full: false),
      page.line("Revenue grew across every region we operate in", gap: 10),
      page.line("during the second quarter.", full: false),
      page.line("Costs stayed flat.", gap: 20, full: false),
    ]

    XCTAssertEqual(
      PDFImporter.markdown(lines: lines),
      """
      # Quarterly Report

      ## Overview

      Revenue grew across every region we operate in during the second quarter.

      Costs stayed flat.
      """)
  }

  func testHyphenatedWordsAreRejoined() {
    var page = Page()
    let lines = [
      page.line("The manufacturing process depends on inter-"),
      page.line("changeable parts.", full: false),
    ]

    XCTAssertEqual(
      PDFImporter.markdown(lines: lines),
      "The manufacturing process depends on interchangeable parts.")
  }

  func testDeliberatelyShortLinesKeepTheirBreaks() {
    var page = Page()
    let lines = [
      page.line("Acme Corporation", full: false),
      page.line("123 Main Street", full: false),
      page.line("Springfield, IL", full: false),
    ]

    XCTAssertEqual(
      PDFImporter.markdown(lines: lines),
      """
      Acme Corporation  
      123 Main Street  
      Springfield, IL
      """)
  }

  func testBulletedAndNestedLists() {
    var page = Page()
    let lines = [
      page.line("Shopping list", size: 18, full: false),
      page.line("\u{2022} Apples", gap: 10, full: false),
      page.line("\u{2022} Bread", full: false),
      page.line("\u{2022} Sourdough", indent: 24, full: false),
      page.line("\u{2022} Milk", full: false),
    ]

    XCTAssertEqual(
      PDFImporter.markdown(lines: lines),
      """
      # Shopping list

      - Apples
      - Bread
        - Sourdough
      - Milk
      """)
  }

  func testNumberedListsAndWrappedItems() {
    var page = Page()
    let lines = [
      page.line("1. Preheat the oven to 200 degrees and wait"),
      page.line("until it beeps.", indent: 18, full: false),
      page.line("2. Add the dough.", full: false),
    ]

    XCTAssertEqual(
      PDFImporter.markdown(lines: lines),
      """
      1. Preheat the oven to 200 degrees and wait until it beeps.
      1. Add the dough.
      """)
  }

  func testInlineEmphasisAndLinks() {
    var page = Page()
    let lines = [
      page.line(
        [
          PDFImporter.Run(text: "A "),
          PDFImporter.Run(text: "bold", bold: true),
          PDFImporter.Run(text: " and "),
          PDFImporter.Run(text: "italic", italic: true),
          PDFImporter.Run(text: " claim, see "),
          PDFImporter.Run(text: "the docs", link: "https://example.com/docs"),
          PDFImporter.Run(text: "."),
        ], full: false)
    ]

    XCTAssertEqual(
      PDFImporter.markdown(lines: lines),
      "A **bold** and *italic* claim, see [the docs](https://example.com/docs).")
  }

  func testBoldStandaloneLineBecomesHeading() {
    var page = Page()
    let lines = [
      page.line("Background", bold: true, full: false),
      page.line("The project started in 2019 and has shipped", gap: 8),
      page.line("every quarter since.", full: false),
    ]

    XCTAssertEqual(
      PDFImporter.markdown(lines: lines),
      """
      # Background

      The project started in 2019 and has shipped every quarter since.
      """)
  }

  func testRunningHeadersAndFootersAreDropped() {
    var lines: [PDFImporter.Line] = []
    for index in 0..<3 {
      var page = Page(index: index)
      lines.append(page.line("Annual Report 2024", size: 9, full: false, top: 40))
      lines.append(page.line("Body text for page \(index + 1).", full: false, top: 300))
      lines.append(page.line("Page \(index + 1) of 3", size: 9, full: false, top: 745))
    }

    XCTAssertEqual(
      PDFImporter.markdown(lines: lines),
      """
      Body text for page 1.

      Body text for page 2.

      Body text for page 3.
      """)
  }

  func testParagraphContinuesAcrossPageBreak() {
    var first = Page(index: 0)
    var second = Page(index: 1)
    let lines = [
      first.line("The committee agreed that the proposal needed"),
      second.line("further review.", full: false, top: 72),
    ]

    XCTAssertEqual(
      PDFImporter.markdown(lines: lines),
      "The committee agreed that the proposal needed further review.")
  }

  func testMarkdownSyntaxInTheSourceIsEscaped() {
    var page = Page()
    let lines = [
      page.line("# not a heading", full: false),
      page.line("2 * 3 [see] later", gap: 20, full: false),
    ]

    XCTAssertEqual(
      PDFImporter.markdown(lines: lines),
      """
      \\# not a heading

      2 \\* 3 \\[see\\] later
      """)
  }

  func testLigaturesAndSoftHyphensAreNormalized() {
    var page = Page()
    let lines = [page.line("The \u{FB01}nal of\u{FB02}ine dif\u{00AD}ference", full: false)]

    XCTAssertEqual(PDFImporter.markdown(lines: lines), "The final offline difference")
  }

  func testEmptyInputProducesNoMarkdown() {
    XCTAssertEqual(PDFImporter.markdown(lines: []), "")
    var page = Page()
    XCTAssertEqual(PDFImporter.markdown(lines: [page.line("   ", full: false)]), "")
  }
}
