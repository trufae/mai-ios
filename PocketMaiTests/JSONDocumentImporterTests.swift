import XCTest

@testable import PocketMai

final class JSONDocumentImporterTests: XCTestCase {
  func testObjectRenderingAndSections() throws {
    let json = """
      {
        "name": "PocketMai",
        "version": 1.5,
        "server": {
          "host": "example.com",
          "ports": [80, 443]
        },
        "flags": [],
        "empty": {},
        "notes": null
      }
      """
    let rendered = try JSONDocumentImporter.render(text: json)
    XCTAssertEqual(
      rendered.text,
      """
      name: PocketMai
      version: 1.5
      server:
        host: example.com
        ports:
          - 80
          - 443
      flags: []
      empty: {}
      notes: null
      """)
    XCTAssertEqual(
      rendered.sections,
      [
        JSONDocumentImporter.Section(line: 3, depth: 0, title: "server"),
        JSONDocumentImporter.Section(line: 5, depth: 1, title: "ports"),
      ])
  }

  func testArraysStringsAndEscapes() throws {
    let json = """
      {
        "items": [
          {"name": "a", "value": 1},
          "plain",
          ["x", "y"]
        ],
        "note": "line one\\nline two",
        "emoji": "\\ud83d\\ude00",
        "empty": ""
      }
      """
    let rendered = try JSONDocumentImporter.render(text: json)
    XCTAssertEqual(
      rendered.text,
      """
      items:
        -
          name: a
          value: 1
        - plain
        -
          - x
          - y
      note:
        line one
        line two
      emoji: \u{1F600}
      empty: ""
      """)
    XCTAssertEqual(
      rendered.sections,
      [JSONDocumentImporter.Section(line: 1, depth: 0, title: "items")])
  }

  func testKeyOrderIsPreserved() throws {
    let json = "{\"zebra\": 1, \"apple\": 2, \"mango\": 3}"
    XCTAssertEqual(
      try JSONDocumentImporter.render(text: json).text,
      """
      zebra: 1
      apple: 2
      mango: 3
      """)
  }

  func testNumberLexemesAreKeptVerbatim() throws {
    let json = "{\"a\": 0.30000000000000004, \"b\": -1e10, \"c\": 12}"
    XCTAssertEqual(
      try JSONDocumentImporter.render(text: json).text,
      """
      a: 0.30000000000000004
      b: -1e10
      c: 12
      """)
  }

  func testTopLevelValues() throws {
    XCTAssertEqual(try JSONDocumentImporter.render(text: "42").text, "42")
    XCTAssertEqual(try JSONDocumentImporter.render(text: "\"hi\"").text, "hi")
    XCTAssertEqual(try JSONDocumentImporter.render(text: "{}").text, "{}")
    XCTAssertEqual(try JSONDocumentImporter.render(text: "[]").text, "[]")
    XCTAssertEqual(
      try JSONDocumentImporter.render(text: "[true, false, null]").text,
      """
      - true
      - false
      - null
      """)
  }

  func testInvalidJSONThrows() {
    XCTAssertThrowsError(try JSONDocumentImporter.render(text: "{\"a\": }"))
    XCTAssertThrowsError(try JSONDocumentImporter.render(text: "[1, 2,]"))
    XCTAssertThrowsError(try JSONDocumentImporter.render(text: "{} extra"))
    XCTAssertThrowsError(try JSONDocumentImporter.render(text: "{\"a\" 1}"))
    XCTAssertThrowsError(try JSONDocumentImporter.render(text: "\"unterminated"))
  }
}
