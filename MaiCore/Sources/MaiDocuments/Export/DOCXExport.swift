import Foundation
import MaiMarkdown

#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
  import ImageIO
  import UniformTypeIdentifiers
#endif

/// Writes a Word document (OOXML): title, dates, and a heading per entry
/// with the markdown turned into styled paragraphs, tables, and pictures.
public enum DOCXExport {
  public static func data(for document: ExportDocument) -> Data {
    let builder = DocumentBuilder(catalog: ExportImageCatalog(document: document))
    builder.appendTitle(document.summary)
    for (index, entry) in document.exportedEntries.enumerated() {
      builder.append(entry, index: index)
    }
    return builder.archive(document)
  }
}

private final class DocumentBuilder {
  private struct EmbeddedImage {
    let relationshipID: String
    let widthEMU: Int
    let heightEMU: Int
  }

  private struct Relationship {
    let id: String
    let type: String
    let target: String
    let isExternal: Bool
  }

  private struct RunStyle {
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var hyperlink = false
  }

  private let catalog: ExportImageCatalog
  private var body = ""
  private var relationships: [Relationship] = []
  private var mediaFiles: [(filename: String, data: Data)] = []
  private var hyperlinkIDs: [String: String] = [:]
  private var embeddedImages: [String: EmbeddedImage?] = [:]
  private var nextRelationship = 1
  private var drawingCount = 0

  // 96 CSS pixels per inch, 914400 EMU per inch.
  private static let emuPerPixel = 9525
  private static let maxImageWidthEMU = 5_943_600  // 6.5 in, the content width
  private static let maxImageHeightEMU = 7_315_200  // 8 in

  init(catalog: ExportImageCatalog) {
    self.catalog = catalog
  }

  // MARK: - Sections

  func appendTitle(_ summary: ExportSummary) {
    body += paragraph(properties(style: "Title"), textRun(summary.title, style: RunStyle()))
    for meta in ["Started \(summary.started)", "Last updated \(summary.lastUpdated)", summary.messageCount] {
      body += paragraph(properties(alignment: "center"), metaRun(meta))
    }
  }

  func append(_ entry: ExportEntry, index: Int) {
    let color: String
    switch entry.role {
    case .user: color = "1A7F37"
    case .assistant: color = "0969DA"
    case .system: color = "57606A"
    case .tool: color = "8250DF"
    case .error: color = "CF222E"
    }
    body += paragraph(
      properties(style: "Heading1"),
      "<w:r><w:rPr><w:caps/><w:color w:val=\"\(color)\"/></w:rPr><w:t xml:space=\"preserve\">\(escaped(entry.role.displayName))</w:t></w:r>"
    )
    for section in entry.reasoning
    where !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      body += paragraph(
        properties(indentLeft: 360),
        "<w:r><w:rPr><w:b/><w:caps/><w:color w:val=\"8250DF\"/><w:sz w:val=\"18\"/><w:szCs w:val=\"18\"/></w:rPr><w:t xml:space=\"preserve\">Reasoning</w:t></w:r>"
      )
      for block in MarkdownBlockParser.blocks(from: section) { append(block, indent: 360) }
    }
    for block in MarkdownBlockParser.blocks(from: entry.body) { append(block, indent: 0) }
    for (offset, image) in entry.attachments.enumerated() {
      guard let resource = catalog.attachment(entry: index, index: offset) else { continue }
      if let embedded = embeddedImage(for: resource) {
        body += paragraph("", drawingRun(embedded, altText: image.name))
      }
      body += paragraph(properties(style: "Caption"), textRun(image.name, style: RunStyle()))
    }
  }

  // MARK: - Blocks

  private func append(_ block: MarkdownBlock, indent: Int) {
    let indentLeft = indent > 0 ? indent : nil
    switch block {
    case .heading(let level, let text):
      body += paragraph(
        properties(style: "Heading\(min(6, max(2, level + 1)))", indentLeft: indentLeft),
        inlineRuns(text, style: RunStyle()))
    case .paragraph(let text):
      body += paragraph(properties(indentLeft: indentLeft), lineRuns(text))
    case .quote(let text):
      body += paragraph(properties(style: "Quote", indentLeft: 360 + indent), lineRuns(text))
    case .rule:
      appendRule(indent: indent)
    case .code(let language, let code):
      if language.lowercased() == "mermaid", let resource = catalog.diagram(source: code),
        let embedded = embeddedImage(for: resource)
      {
        body += paragraph(properties(indentLeft: indentLeft), drawingRun(embedded, altText: "Mermaid diagram"))
      } else {
        let runs = code.components(separatedBy: "\n").map {
          "<w:r><w:t xml:space=\"preserve\">\(escaped($0))</w:t></w:r>"
        }.joined(separator: "<w:r><w:br/></w:r>")
        body += paragraph(properties(style: "CodeBlock", indentLeft: indentLeft), runs)
      }
    case .table(let table):
      appendTable(table, indent: indent)
    case .bullets(let items):
      for item in items { appendListItem(marker: "\u{2022}", text: item, indent: indent) }
    case .ordered(let items):
      for item in items { appendListItem(marker: item.label, text: item.text, indent: indent) }
    case .tasks(let items):
      for item in items {
        appendListItem(marker: item.checked ? "\u{2611}" : "\u{2610}", text: item.text, indent: indent)
      }
    case .footnotes(let items):
      appendRule(indent: indent)
      for item in items {
        let key =
          "<w:r><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr><w:t xml:space=\"preserve\">\(escaped(item.key))</w:t></w:r>"
        body += paragraph(
          properties(indentLeft: indentLeft),
          key + textRun(" ", style: RunStyle()) + inlineRuns(item.text, style: RunStyle()))
      }
    }
  }

  private func lineRuns(_ text: String) -> String {
    text.components(separatedBy: "\n").map { inlineRuns($0, style: RunStyle()) }
      .joined(separator: "<w:r><w:br/></w:r>")
  }

  private func appendRule(indent: Int) {
    let border =
      "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"D0D7DE\"/></w:pBdr>"
    body += paragraph(properties(border: border, indentLeft: indent > 0 ? indent : nil), "")
  }

  private func appendListItem(marker: String, text: String, indent: Int) {
    let markerRun = "<w:r><w:t xml:space=\"preserve\">\(escaped(marker))\u{00A0}</w:t></w:r>"
    body += paragraph(
      properties(indentLeft: indent + 432, hanging: 216),
      markerRun + inlineRuns(text, style: RunStyle()))
  }

  private func appendTable(_ table: MarkdownTable, indent: Int) {
    let columnCount = max(table.headers.count, table.rows.map(\.count).max() ?? 0)
    guard columnCount > 0 else { return }
    func alignment(_ index: Int) -> String? {
      guard index < table.alignments.count else { return nil }
      switch table.alignments[index] {
      case .center: return "center"
      case .trailing: return "right"
      case .leading: return nil
      }
    }
    func row(_ cells: [String], isHeader: Bool) -> String {
      var xml = "<w:tr>"
      for column in 0..<columnCount {
        var style = RunStyle()
        style.bold = isHeader
        let shading = isHeader ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F6F8FA\"/>" : ""
        let text = column < cells.count ? cells[column] : ""
        let cell = paragraph(properties(alignment: alignment(column)), inlineRuns(text, style: style))
        xml += "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/>\(shading)</w:tcPr>\(cell)</w:tc>"
      }
      return xml + "</w:tr>"
    }
    let borders = ["top", "left", "bottom", "right", "insideH", "insideV"].map {
      "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"D0D7DE\"/>"
    }.joined()
    let tableIndent = indent > 0 ? "<w:tblInd w:w=\"\(indent)\" w:type=\"dxa\"/>" : ""
    let grid = (0..<columnCount).map { _ in "<w:gridCol w:w=\"\(9360 / columnCount)\"/>" }.joined()
    var xml =
      "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/>\(tableIndent)<w:tblBorders>\(borders)</w:tblBorders></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>"
    if !table.headers.isEmpty { xml += row(table.headers, isHeader: true) }
    for cells in table.rows { xml += row(cells, isHeader: false) }
    body += xml + "</w:tbl><w:p/>"
  }

  // MARK: - Inline runs

  private func inlineRuns(_ raw: String, style base: RunStyle) -> String {
    var result = ""
    for run in MarkdownInlineParser.runs(from: raw) {
      if run.style.contains(.image) {
        let source = run.destination ?? ""
        if let resource = catalog.inlineImage(source: source), let embedded = embeddedImage(for: resource) {
          result += drawingRun(embedded, altText: run.text)
        } else if let id = hyperlinkID(for: source) {
          var style = base
          style.hyperlink = true
          let label = run.text.trimmingCharacters(in: .whitespaces).isEmpty ? source : run.text
          result += hyperlink(id, textRun(label, style: style))
        } else {
          result += textRun("![\(run.text)](\(source))", style: base)
        }
        continue
      }
      var style = base
      if run.style.contains(.bold) { style.bold = true }
      if run.style.contains(.italic) { style.italic = true }
      if run.style.contains(.strikethrough) { style.strike = true }
      if run.style.contains(.code) { style.code = true }
      let pieces = run.text.components(separatedBy: "\n")
      var text = ""
      for (index, piece) in pieces.enumerated() {
        if index > 0 { text += "<w:r><w:br/></w:r>" }
        text += textRun(piece, style: style)
      }
      let destination = run.style.contains(.link) ? run.destination : (style.code ? run.text : nil)
      if let destination, let id = hyperlinkID(for: destination) {
        style.hyperlink = true
        result += hyperlink(id, pieces.map { textRun($0, style: style) }.joined(separator: "<w:r><w:br/></w:r>"))
      } else {
        result += text
      }
    }
    return result
  }

  private func hyperlink(_ relationshipID: String, _ inner: String) -> String {
    "<w:hyperlink r:id=\"\(relationshipID)\">\(inner)</w:hyperlink>"
  }

  private func textRun(_ text: String, style: RunStyle) -> String {
    guard !text.isEmpty else { return "" }
    var properties = ""
    if style.hyperlink { properties += "<w:rStyle w:val=\"Hyperlink\"/>" }
    if style.code {
      properties += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>"
    }
    if style.bold { properties += "<w:b/>" }
    if style.italic { properties += "<w:i/>" }
    if style.strike { properties += "<w:strike/>" }
    if style.code {
      properties += "<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/>"
      properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F6F8FA\"/>"
    }
    let runProperties = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
    return "<w:r>\(runProperties)<w:t xml:space=\"preserve\">\(escaped(text))</w:t></w:r>"
  }

  private func metaRun(_ text: String) -> String {
    "<w:r><w:rPr><w:color w:val=\"57606A\"/><w:sz w:val=\"18\"/><w:szCs w:val=\"18\"/></w:rPr><w:t xml:space=\"preserve\">\(escaped(text))</w:t></w:r>"
  }

  // MARK: - Images

  private func embeddedImage(for resource: ExportResource) -> EmbeddedImage? {
    if let cached = embeddedImages[resource.href] { return cached }
    let embedded = makeEmbeddedImage(for: resource)
    embeddedImages[resource.href] = embedded
    return embedded
  }

  private func makeEmbeddedImage(for resource: ExportResource) -> EmbeddedImage? {
    guard let picture = WordPicture.make(from: resource) else { return nil }
    var widthEMU = max(1, picture.width) * Self.emuPerPixel
    var heightEMU = max(1, picture.height) * Self.emuPerPixel
    if widthEMU > Self.maxImageWidthEMU {
      heightEMU = heightEMU * Self.maxImageWidthEMU / widthEMU
      widthEMU = Self.maxImageWidthEMU
    }
    if heightEMU > Self.maxImageHeightEMU {
      widthEMU = widthEMU * Self.maxImageHeightEMU / heightEMU
      heightEMU = Self.maxImageHeightEMU
    }
    let filename = "image\(mediaFiles.count + 1).\(picture.fileExtension)"
    mediaFiles.append((filename, picture.data))
    let relationshipID = addRelationship(
      type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
      target: "media/\(filename)",
      isExternal: false)
    return EmbeddedImage(
      relationshipID: relationshipID, widthEMU: max(1, widthEMU), heightEMU: max(1, heightEMU))
  }

  private func drawingRun(_ image: EmbeddedImage, altText: String) -> String {
    drawingCount += 1
    let id = drawingCount
    let name = escaped("Image \(id)")
    let description = escaped(altText)
    return """
      <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
      <wp:extent cx="\(image.widthEMU)" cy="\(image.heightEMU)"/>\
      <wp:docPr id="\(id)" name="\(name)" descr="\(description)"/>\
      <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
      <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
      <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
      <pic:nvPicPr><pic:cNvPr id="\(id)" name="\(name)" descr="\(description)"/>\
      <pic:cNvPicPr/></pic:nvPicPr>\
      <pic:blipFill><a:blip r:embed="\(image.relationshipID)"/>\
      <a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
      <pic:spPr><a:xfrm><a:off x="0" y="0"/>\
      <a:ext cx="\(image.widthEMU)" cy="\(image.heightEMU)"/></a:xfrm>\
      <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
      </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
      """
  }

  // MARK: - Relationships

  private func hyperlinkID(for url: String) -> String? {
    guard let target = ExportXML.webURL(url) else { return nil }
    if let existing = hyperlinkIDs[target] { return existing }
    let id = addRelationship(
      type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
      target: target,
      isExternal: true)
    hyperlinkIDs[target] = id
    return id
  }

  private func addRelationship(type: String, target: String, isExternal: Bool) -> String {
    nextRelationship += 1
    let id = "rId\(nextRelationship)"
    relationships.append(Relationship(id: id, type: type, target: target, isExternal: isExternal))
    return id
  }

  // MARK: - Packaging

  func archive(_ document: ExportDocument) -> Data {
    let documentXML = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
      xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">\
      <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" \
      w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
      """
    let styles = Relationship(
      id: "rId1",
      type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles",
      target: "styles.xml",
      isExternal: false)
    let documentRelationships = ([styles] + relationships).map { relationship in
      "<Relationship Id=\"\(relationship.id)\" Type=\"\(relationship.type)\" Target=\"\(escaped(relationship.target))\""
        + (relationship.isExternal ? " TargetMode=\"External\"" : "") + "/>"
    }.joined()
    let documentRels = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(documentRelationships)</Relationships>
      """
    let packageRels = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
      """
    let contentTypes = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
      <Default Extension="xml" ContentType="application/xml"/>\
      <Default Extension="png" ContentType="image/png"/>\
      <Default Extension="jpg" ContentType="image/jpeg"/>\
      <Default Extension="jpeg" ContentType="image/jpeg"/>\
      <Default Extension="gif" ContentType="image/gif"/>\
      <Default Extension="bmp" ContentType="image/bmp"/>\
      <Default Extension="tif" ContentType="image/tiff"/>\
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
      <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
      <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
      <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
      """
    let core = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
      xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
      <dc:title>\(escaped(document.summary.title))</dc:title>\
      <dcterms:created xsi:type="dcterms:W3CDTF">\(ExportXML.iso8601(document.createdAt))</dcterms:created>\
      <dcterms:modified xsi:type="dcterms:W3CDTF">\(ExportXML.iso8601(document.updatedAt))</dcterms:modified>\
      </cp:coreProperties>
      """
    let app = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
      xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
      <Application>\(escaped(document.generator))</Application></Properties>
      """
    var entries: [(path: String, data: Data)] = [
      ("[Content_Types].xml", Data(contentTypes.utf8)),
      ("_rels/.rels", Data(packageRels.utf8)),
      ("docProps/core.xml", Data(core.utf8)),
      ("docProps/app.xml", Data(app.utf8)),
      ("word/document.xml", Data(documentXML.utf8)),
      ("word/styles.xml", Data(Self.stylesXML.utf8)),
      ("word/_rels/document.xml.rels", Data(documentRels.utf8)),
    ]
    for media in mediaFiles {
      entries.append(("word/media/\(media.filename)", media.data))
    }
    return ZipArchiveWriter.archive(entries: entries)
  }

  // MARK: - XML helpers

  private func paragraph(_ properties: String, _ runs: String) -> String {
    "<w:p>\(properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>")\(runs)</w:p>"
  }

  private func properties(
    style: String? = nil,
    border: String? = nil,
    indentLeft: Int? = nil,
    hanging: Int? = nil,
    alignment: String? = nil
  ) -> String {
    var xml = ""
    if let style { xml += "<w:pStyle w:val=\"\(style)\"/>" }
    if let border { xml += border }
    if indentLeft != nil || hanging != nil {
      xml += "<w:ind"
      if let indentLeft { xml += " w:left=\"\(indentLeft)\"" }
      if let hanging { xml += " w:hanging=\"\(hanging)\"" }
      xml += "/>"
    }
    if let alignment { xml += "<w:jc w:val=\"\(alignment)\"/>" }
    return xml
  }

  private func escaped(_ value: String) -> String {
    ExportXML.escaped(value)
  }

  private static let stylesXML: String = {
    let headingSizes = [28, 26, 24, 23, 22, 22]
    let headings = (1...6).map { level in
      """
      <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/>\
      <w:basedOn w:val="Normal"/><w:qFormat/>\
      <w:pPr><w:keepNext/><w:spacing w:before="\(level == 1 ? 360 : level <= 3 ? 240 : 200)" \
      w:after="\(level == 1 ? 120 : 80)"/><w:outlineLvl w:val="\(level - 1)"/></w:pPr>\
      <w:rPr><w:b/>\(level == 6 ? "<w:i/>" : "")<w:sz w:val="\(headingSizes[level - 1])"/>\
      <w:szCs w:val="\(headingSizes[level - 1])"/></w:rPr></w:style>
      """
    }.joined()
    return """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
      <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault>\
      <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
      <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/></w:style>\
      <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/>\
      <w:pPr><w:spacing w:before="480" w:after="240"/><w:jc w:val="center"/></w:pPr>\
      <w:rPr><w:b/><w:sz w:val="48"/><w:szCs w:val="48"/></w:rPr></w:style>\
      \(headings)\
      <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>\
      <w:pPr><w:pBdr><w:left w:val="single" w:sz="12" w:space="4" w:color="D0D7DE"/></w:pBdr></w:pPr>\
      <w:rPr><w:color w:val="57606A"/></w:rPr></w:style>\
      <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/><w:basedOn w:val="Normal"/><w:qFormat/>\
      <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F6F8FA"/>\
      <w:spacing w:before="120" w:after="160" w:line="240" w:lineRule="auto"/></w:pPr>\
      <w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/>\
      <w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>\
      <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:qFormat/>\
      <w:pPr><w:spacing w:after="240"/></w:pPr>\
      <w:rPr><w:i/><w:color w:val="57606A"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>\
      <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/>\
      <w:rPr><w:color w:val="0969DA"/><w:u w:val="single"/></w:rPr></w:style>\
      </w:styles>
      """
  }()
}

/// An image in a form Word displays, with its pixel size. Formats Word cannot
/// show (WebP, HEIC, SVG) are re-encoded as PNG where ImageIO is available and
/// dropped elsewhere.
private struct WordPicture {
  var data: Data
  var fileExtension: String
  var width: Int
  var height: Int

  private static let supported: [String: String] = [
    "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/bmp": "bmp",
    "image/tiff": "tif",
  ]

  static func make(from resource: ExportResource) -> WordPicture? {
    if let fileExtension = supported[resource.mediaType.lowercased()] {
      if let width = resource.width, let height = resource.height, width > 0, height > 0 {
        return WordPicture(data: resource.data, fileExtension: fileExtension, width: width, height: height)
      }
      let size = pixelSize(of: resource.data) ?? (600, 400)
      return WordPicture(data: resource.data, fileExtension: fileExtension, width: size.0, height: size.1)
    }
    guard let png = pngData(from: resource.data), let size = pixelSize(of: png) else { return nil }
    return WordPicture(data: png, fileExtension: "png", width: size.0, height: size.1)
  }

  static func pixelSize(of data: Data) -> (Int, Int)? {
    #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
      else { return nil }
      return (width, height)
    #else
      return nil
    #endif
  }

  static func pngData(from data: Data) -> Data? {
    #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }
      let output = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          output, UTType.png.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return output as Data
    #else
      return nil
    #endif
  }
}
