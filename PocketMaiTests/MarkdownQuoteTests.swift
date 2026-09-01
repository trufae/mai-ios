import Foundation
import XCTest

@testable import PocketMai

final class MarkdownQuoteTests: XCTestCase {
  func testWrapsAndPrefixesEveryLine() {
    let quoted = MarkdownQuote.quote("The quick brown fox jumps over the lazy dog")

    XCTAssertEqual(
      quoted,
      """
      > The quick brown
      > fox jumps over the
      > lazy dog
      """)
  }

  func testEveryLineFitsTheConfiguredWidth() {
    let text = "Assistants answer questions about wrapping behaviour in narrow bubbles."
    let quoted = MarkdownQuote.quote(text)

    for line in quoted.components(separatedBy: "\n") {
      XCTAssertTrue(line.hasPrefix("> "), "Missing quote marker: \(line)")
      XCTAssertLessThanOrEqual(line.count, MarkdownQuote.defaultLineWidth, "Too long: \(line)")
    }
  }

  func testKeepsBlankLinesInsideTheQuote() {
    let quoted = MarkdownQuote.quote("first\n\nsecond")

    XCTAssertEqual(
      quoted,
      """
      > first
      >
      > second
      """)
    XCTAssertFalse(quoted.contains("> \n"), "Blank quoted lines must not carry trailing spaces")
  }

  func testSplitsWordsThatCannotFitOnALineOfTheirOwn() {
    let quoted = MarkdownQuote.quote("see https://example.com/some/very/long/path")

    for line in quoted.components(separatedBy: "\n") {
      XCTAssertLessThanOrEqual(line.count, MarkdownQuote.defaultLineWidth, "Too long: \(line)")
    }
    XCTAssertEqual(
      quoted.replacingOccurrences(of: "> ", with: "").replacingOccurrences(of: "\n", with: ""),
      "see https://example.com/some/very/long/path".replacingOccurrences(of: " ", with: ""))
  }

  func testHonoursACustomWidthAndNormalizesWindowsNewlines() {
    let quoted = MarkdownQuote.quote("alpha beta\r\ngamma", lineWidth: 12)

    XCTAssertEqual(
      quoted,
      """
      > alpha beta
      > gamma
      """)
  }

  func testEmptyTextProducesAnEmptyQuotedLine() {
    XCTAssertEqual(MarkdownQuote.quote(""), ">")
  }
}
