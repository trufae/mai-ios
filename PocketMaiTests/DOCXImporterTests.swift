import XCTest

@testable import PocketMai

final class DOCXImporterTests: XCTestCase {
  private func markdown(document: String, numbering: String? = nil, relationships: String? = nil)
    throws -> String
  {
    var parts: [String: Data] = ["word/document.xml": Data(document.utf8)]
    if let numbering {
      parts["word/numbering.xml"] = Data(numbering.utf8)
    }
    if let relationships {
      parts["word/_rels/document.xml.rels"] = Data(relationships.utf8)
    }
    return try DOCXImporter.markdown(parts: parts)
  }

  private func body(_ content: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document \
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <w:body>\(content)</w:body></w:document>
    """
  }

  func testHeadingsAndParagraphs() throws {
    let xml = body(
      """
      <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Quarterly Report</w:t></w:r></w:p>
      <w:p><w:pPr><w:pStyle w:val="Heading 2"/></w:pPr><w:r><w:t>Overview</w:t></w:r></w:p>
      <w:p><w:r><w:t>Plain paragraph.</w:t></w:r></w:p>
      <w:p/>
      """)

    XCTAssertEqual(
      try markdown(document: xml),
      """
      # Quarterly Report

      ## Overview

      Plain paragraph.
      """)
  }

  func testRunStylesLinksAndBreaks() throws {
    let relationships = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://x/styles" Target="styles.xml"/>
      <Relationship Id="rId7" Type="http://x/hyperlink" \
      Target="https://example.com/dash?q=1" TargetMode="External"/>
      </Relationships>
      """
    let xml = body(
      """
      <w:p>
      <w:r><w:t xml:space="preserve">Revenue was </w:t></w:r>
      <w:r><w:rPr><w:b/></w:rPr><w:t>up 12%</w:t></w:r>
      <w:r><w:t xml:space="preserve"> versus </w:t></w:r>
      <w:r><w:rPr><w:i/></w:rPr><w:t>last</w:t></w:r>
      <w:r><w:rPr><w:i/></w:rPr><w:t> year</w:t></w:r>
      <w:r><w:t xml:space="preserve">. See </w:t></w:r>
      <w:hyperlink r:id="rId7"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr>\
      <w:t>the dashboard</w:t></w:r></w:hyperlink>
      <w:r><w:t xml:space="preserve"> and run </w:t></w:r>
      <w:r><w:rPr><w:rStyle w:val="HTMLCode"/></w:rPr><w:t>make build</w:t></w:r>
      <w:r><w:t>.</w:t></w:r>
      <w:r><w:br/><w:t>Second line.</w:t></w:r>
      </w:p>
      """)

    // The <w:br/> becomes a hard line break: two trailing spaces before the newline.
    let expected =
      "Revenue was **up 12%** versus *last year*. "
      + "See [the dashboard](https://example.com/dash?q=1) and run `make build`.  \n"
      + "Second line."
    XCTAssertEqual(try markdown(document: xml, relationships: relationships), expected)
  }

  func testBulletedAndNumberedLists() throws {
    let numbering = """
      <?xml version="1.0" encoding="UTF-8"?>
      <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:abstractNum w:abstractNumId="0">
      <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
      <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
      </w:abstractNum>
      <w:abstractNum w:abstractNumId="1">
      <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="2"><w:abstractNumId w:val="0"/></w:num>
      <w:num w:numId="3"><w:abstractNumId w:val="1"/></w:num>
      </w:numbering>
      """
    let xml = body(
      """
      <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/>\
      <w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>First bullet</w:t></w:r></w:p>
      <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="1"/>\
      <w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>Nested bullet</w:t></w:r></w:p>
      <w:p><w:pPr><w:pStyle w:val="Quote"/></w:pPr><w:r><w:t>Estimates only.</w:t></w:r></w:p>
      <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/>\
      <w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t>Step one</w:t></w:r></w:p>
      <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/>\
      <w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t>Step two</w:t></w:r></w:p>
      """)

    XCTAssertEqual(
      try markdown(document: xml, numbering: numbering),
      """
      - First bullet
        - Nested bullet

      > Estimates only.

      1. Step one
      1. Step two
      """)
  }

  func testTablesBecomePipeTables() throws {
    let xml = body(
      """
      <w:tbl>
      <w:tr><w:tc><w:p><w:r><w:t>Region</w:t></w:r></w:p></w:tc>
      <w:tc><w:p><w:r><w:t>Sales | net</w:t></w:r></w:p></w:tc></w:tr>
      <w:tr><w:tc><w:p><w:r><w:t>EU</w:t></w:r></w:p>\
      <w:p><w:r><w:t>(incl. UK)</w:t></w:r></w:p></w:tc>
      <w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>1,200</w:t></w:r></w:p></w:tc></w:tr>
      </w:tbl>
      """)

    XCTAssertEqual(
      try markdown(document: xml),
      """
      | Region | Sales \\| net |
      | --- | --- |
      | EU<br>(incl. UK) | **1,200** |
      """)
  }

  func testMarkdownSyntaxInDocumentTextIsEscaped() throws {
    let xml = body(
      """
      <w:p><w:r><w:t># not a heading, a * star and [brackets]</w:t></w:r></w:p>
      <w:p><w:r><w:t>2. not a numbered list</w:t></w:r></w:p>
      """)

    XCTAssertEqual(
      try markdown(document: xml),
      """
      \\# not a heading, a \\* star and \\[brackets\\]

      2\\. not a numbered list
      """)
  }

  func testTrackedDeletionsAndPropertiesAreIgnored() throws {
    let xml = body(
      """
      <w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs>\
      <w:rPr><w:b/></w:rPr></w:pPr>
      <w:r><w:t>Kept</w:t></w:r>
      <w:del><w:r><w:delText> removed</w:delText></w:r></w:del>
      <w:ins><w:r><w:t xml:space="preserve"> added</w:t></w:r></w:ins>
      </w:p>
      """)

    XCTAssertEqual(try markdown(document: xml), "Kept added")
  }

  func testMissingBodyThrows() throws {
    XCTAssertThrowsError(try DOCXImporter.markdown(parts: [:])) { error in
      XCTAssertEqual(error as? DOCXImporter.ImportError, .missingDocument)
    }
  }

  func testDocumentWithoutTextThrows() throws {
    XCTAssertThrowsError(try markdown(document: body("<w:p/>"))) { error in
      XCTAssertEqual(error as? DOCXImporter.ImportError, .emptyDocument)
    }
  }
}
