import Foundation
import SwiftUI
import UIKit

enum DOCXExporter {
  static func makeDOCX(
    conversation: Conversation,
    includeThinking: Bool? = nil,
    imageSize: AttachmentImageSize = .full
  ) async throws -> Data {
    let title = conversation.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let documentTitle = title.isEmpty ? "Chat" : title
    let shouldIncludeThinking = includeThinking ?? conversation.showThinking

    let imageCatalog = try await EPUBExporter.buildImageResourceCatalog(
      conversation: conversation,
      includeThinking: shouldIncludeThinking,
      imageSize: imageSize)

    let builder = DocumentBuilder(imageCatalog: imageCatalog)
    builder.appendTitleSection(conversation: conversation, documentTitle: documentTitle)
    for message in conversation.messages {
      let content = EPUBExporter.messageContent(
        for: message,
        includeThinking: shouldIncludeThinking)
      guard content.hasExportedBody || imageCatalog.hasImageAttachments(for: message) else {
        continue
      }
      builder.appendMessage(message, content: content)
    }
    return builder.archive(documentTitle: documentTitle, conversation: conversation)
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

  private let imageCatalog: EPUBExporter.ImageResourceCatalog
  private var body = ""
  private var relationships: [Relationship] = []
  private var mediaFiles: [(filename: String, data: Data)] = []
  private var hyperlinkIDsByURL: [String: String] = [:]
  private var embeddedImagesByHref: [String: EmbeddedImage?] = [:]
  private var nextRelationshipIndex = 1
  private var drawingCount = 0

  // 96 CSS pixels per inch, 914400 EMU per inch.
  private static let emuPerPixel = 9525
  private static let maxImageWidthEMU = 5_943_600  // 6.5 in, the content width
  private static let maxImageHeightEMU = 7_315_200  // 8 in

  init(imageCatalog: EPUBExporter.ImageResourceCatalog) {
    self.imageCatalog = imageCatalog
  }

  // MARK: - Sections

  func appendTitleSection(conversation: Conversation, documentTitle: String) {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .long
    dateFormatter.timeStyle = .short
    let created = dateFormatter.string(from: conversation.createdAt)
    let updated = dateFormatter.string(from: conversation.updatedAt)
    let messageCount = conversation.messages.count

    body += paragraph(
      paragraphProperties(style: "Title"),
      textRun(documentTitle, style: RunStyle()))
    for meta in [
      "Started \(created)",
      "Last updated \(updated)",
      "\(messageCount) message\(messageCount == 1 ? "" : "s")",
    ] {
      body += paragraph(
        paragraphProperties(alignment: "center"),
        metaRun(meta))
    }
  }

  func appendMessage(_ message: ChatMessage, content: EPUBExporter.MessageContent) {
    appendRoleHeading(message.role)
    for section in content.reasoningSections {
      appendReasoningSection(section)
    }
    if !content.visibleText.isEmpty {
      for block in MarkdownParser.blocks(from: content.visibleText) {
        appendBlock(block, indent: 0)
      }
    }
    appendImageAttachments(for: message)
  }

  private func appendRoleHeading(_ role: ChatRole) {
    let color: String
    switch role {
    case .user: color = "1A7F37"
    case .assistant: color = "0969DA"
    case .system: color = "57606A"
    case .tool: color = "8250DF"
    case .error: color = "CF222E"
    }
    let run = """
      <w:r><w:rPr><w:caps/><w:color w:val="\(color)"/></w:rPr>\
      <w:t xml:space="preserve">\(xmlEscaped(role.displayName))</w:t></w:r>
      """
    body += paragraph(paragraphProperties(style: "Heading1"), run)
  }

  private func appendReasoningSection(_ text: String) {
    let label = """
      <w:r><w:rPr><w:b/><w:caps/><w:color w:val="8250DF"/><w:sz w:val="18"/>\
      <w:szCs w:val="18"/></w:rPr><w:t xml:space="preserve">Reasoning</w:t></w:r>
      """
    body += paragraph(paragraphProperties(indentLeft: 360), label)
    for block in MarkdownParser.blocks(from: text) {
      appendBlock(block, indent: 360)
    }
  }

  // MARK: - Blocks

  private func appendBlock(_ block: MarkdownBlock, indent: Int) {
    switch block.kind {
    case .heading(let level, let text):
      let style = "Heading\(min(6, max(2, level + 1)))"
      body += paragraph(
        paragraphProperties(style: style, indentLeft: indent > 0 ? indent : nil),
        inlineRuns(text, style: RunStyle()))
    case .text(let value):
      appendTextParagraphs(value, indent: indent)
    case .blockquote(let value):
      appendQuoteParagraph(value, indent: indent)
    case .horizontalRule:
      appendHorizontalRule(indent: indent)
    case .code(_, let code):
      appendCodeParagraph(code, indent: indent)
    case .mermaid(let source):
      if let resource = imageCatalog.resource(forMermaidDiagram: source),
        let embedded = embeddedImage(for: resource)
      {
        body += paragraph(
          paragraphProperties(indentLeft: indent > 0 ? indent : nil),
          drawingRun(embedded, altText: "Mermaid diagram"))
      } else {
        appendCodeParagraph(source, indent: indent)
      }
    case .table(let headers, let rows, let alignments):
      appendTable(headers: headers, rows: rows, alignments: alignments, indent: indent)
    case .taskList(let items):
      for item in items {
        appendListParagraph(
          marker: item.checked ? "\u{2611}" : "\u{2610}",
          text: item.text,
          indent: indent)
      }
    case .bulletList(let items):
      for item in items {
        appendListParagraph(marker: "\u{2022}", text: item, indent: indent)
      }
    case .orderedList(let items):
      for item in items {
        appendListParagraph(marker: item.marker, text: item.text, indent: indent)
      }
    case .footnotes(let items):
      appendHorizontalRule(indent: indent)
      for item in items {
        let key = """
          <w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr>\
          <w:t xml:space="preserve">\(xmlEscaped(item.key))</w:t></w:r>
          """
        let runs = key + textRun(" ", style: RunStyle()) + inlineRuns(item.text, style: RunStyle())
        body += paragraph(
          paragraphProperties(indentLeft: indent > 0 ? indent : nil),
          runs)
      }
    }
  }

  private func appendTextParagraphs(_ text: String, indent: Int) {
    for para in text.components(separatedBy: "\n\n") {
      let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if trimmed.hasPrefix(">") {
        appendQuoteParagraph(trimmed, indent: indent)
        continue
      }
      let lines = trimmed.components(separatedBy: "\n")
      var runs = ""
      for (index, line) in lines.enumerated() {
        if index > 0 {
          runs += "<w:r><w:br/></w:r>"
        }
        runs += inlineRuns(line, style: RunStyle())
      }
      body += paragraph(
        paragraphProperties(indentLeft: indent > 0 ? indent : nil),
        runs)
    }
  }

  private func appendQuoteParagraph(_ text: String, indent: Int) {
    var runs = ""
    for (index, line) in text.components(separatedBy: "\n").enumerated() {
      var trimmed = line
      if trimmed.hasPrefix("> ") {
        trimmed.removeFirst(2)
      } else if trimmed.hasPrefix(">") {
        trimmed.removeFirst()
      }
      if index > 0 {
        runs += "<w:r><w:br/></w:r>"
      }
      runs += inlineRuns(trimmed, style: RunStyle())
    }
    body += paragraph(
      paragraphProperties(style: "Quote", indentLeft: 360 + indent),
      runs)
  }

  private func appendCodeParagraph(_ code: String, indent: Int) {
    var runs = ""
    let lines = code.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
      if index > 0 {
        runs += "<w:r><w:br/></w:r>"
      }
      runs += "<w:r><w:t xml:space=\"preserve\">\(xmlEscaped(line))</w:t></w:r>"
    }
    body += paragraph(
      paragraphProperties(style: "CodeBlock", indentLeft: indent > 0 ? indent : nil),
      runs)
  }

  private func appendHorizontalRule(indent: Int) {
    let border =
      "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"D0D7DE\"/></w:pBdr>"
    body += paragraph(
      paragraphProperties(border: border, indentLeft: indent > 0 ? indent : nil),
      "")
  }

  private func appendListParagraph(marker: String, text: String, indent: Int) {
    let markerRun =
      "<w:r><w:t xml:space=\"preserve\">\(xmlEscaped(marker))\u{00A0}</w:t></w:r>"
    body += paragraph(
      paragraphProperties(indentLeft: indent + 432, hanging: 216),
      markerRun + inlineRuns(text, style: RunStyle()))
  }

  private func appendTable(
    headers: [String],
    rows: [[String]],
    alignments: [TextAlignment],
    indent: Int
  ) {
    let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
    guard columnCount > 0 else { return }

    func alignment(_ index: Int) -> String? {
      guard index < alignments.count else { return nil }
      switch alignments[index] {
      case .center: return "center"
      case .trailing: return "right"
      default: return nil
      }
    }

    func cell(_ text: String, columnIndex: Int, isHeader: Bool) -> String {
      var style = RunStyle()
      style.bold = isHeader
      let shading = isHeader ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F6F8FA\"/>" : ""
      let properties = paragraphProperties(alignment: alignment(columnIndex))
      let paragraphXML = paragraph(properties, inlineRuns(text, style: style))
      return """
        <w:tc><w:tcPr><w:tcW w:w="0" w:type="auto"/>\(shading)</w:tcPr>\(paragraphXML)</w:tc>
        """
    }

    func row(_ cells: [String], isHeader: Bool) -> String {
      var xml = "<w:tr>"
      for column in 0..<columnCount {
        let text = column < cells.count ? cells[column] : ""
        xml += cell(text, columnIndex: column, isHeader: isHeader)
      }
      xml += "</w:tr>"
      return xml
    }

    let borderEdges = ["top", "left", "bottom", "right", "insideH", "insideV"]
    let borders = borderEdges.map {
      "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"D0D7DE\"/>"
    }.joined()
    let tableIndent =
      indent > 0 ? "<w:tblInd w:w=\"\(indent)\" w:type=\"dxa\"/>" : ""
    let columnWidth = 9360 / columnCount
    let grid = (0..<columnCount).map { _ in "<w:gridCol w:w=\"\(columnWidth)\"/>" }.joined()

    var xml = """
      <w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>\(tableIndent)\
      <w:tblBorders>\(borders)</w:tblBorders></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>
      """
    if !headers.isEmpty {
      xml += row(headers, isHeader: true)
    }
    for cells in rows {
      xml += row(cells, isHeader: false)
    }
    xml += "</w:tbl><w:p/>"
    body += xml
  }

  private func appendImageAttachments(for message: ChatMessage) {
    for attachment in message.attachments where attachment.kind == .image {
      guard let resource = imageCatalog.resource(for: attachment) else { continue }
      if let embedded = embeddedImage(for: resource) {
        body += paragraph("", drawingRun(embedded, altText: attachment.displayName))
      }
      body += paragraph(
        paragraphProperties(style: "Caption"),
        textRun(attachment.displayName, style: RunStyle()))
    }
  }

  // MARK: - Inline runs

  private func inlineRuns(_ raw: String, style: RunStyle) -> String {
    let chars = Array(MarkdownInlineSymbols.displayString(raw))
    var result = ""
    var pending = ""

    func flush() {
      if !pending.isEmpty {
        result += textRun(pending, style: style)
        pending = ""
      }
    }

    var index = 0
    while index < chars.count {
      let c = chars[index]

      if c == "\\", index + 1 < chars.count {
        let next = chars[index + 1]
        if "\\`*_{}[]()#+-.!~".contains(next) {
          pending.append(next)
          index += 2
          continue
        }
      }

      if let codeSpan = MarkdownInlineCodeSpan.span(in: chars, at: index) {
        flush()
        var codeStyle = style
        codeStyle.code = true
        if let href = MarkdownWebURL.normalizedString(from: codeSpan.code),
          let relationshipID = hyperlinkRelationshipID(for: href)
        {
          codeStyle.hyperlink = true
          result +=
            "<w:hyperlink r:id=\"\(relationshipID)\">\(textRun(codeSpan.code, style: codeStyle))</w:hyperlink>"
        } else {
          result += textRun(codeSpan.code, style: codeStyle)
        }
        index = codeSpan.end
        continue
      }

      if c == "~", index + 1 < chars.count, chars[index + 1] == "~" {
        if let end = findClose(chars: chars, start: index + 2, marker: "~~") {
          let inner = String(chars[(index + 2)..<end])
          if !inner.isEmpty {
            flush()
            var strikeStyle = style
            strikeStyle.strike = true
            result += inlineRuns(inner, style: strikeStyle)
            index = end + 2
            continue
          }
        }
      }

      if (c == "*" || c == "_") && index + 1 < chars.count && chars[index + 1] == c {
        let marker = String([c, c])
        if let end = findClose(chars: chars, start: index + 2, marker: marker) {
          let inner = String(chars[(index + 2)..<end])
          flush()
          var boldStyle = style
          boldStyle.bold = true
          result += inlineRuns(inner, style: boldStyle)
          index = end + marker.count
          continue
        }
      }

      if c == "*" || c == "_" {
        if let end = findClose(chars: chars, start: index + 1, marker: String(c)) {
          let inner = String(chars[(index + 1)..<end])
          if !inner.isEmpty {
            flush()
            var italicStyle = style
            italicStyle.italic = true
            result += inlineRuns(inner, style: italicStyle)
            index = end + 1
            continue
          }
        }
      }

      if let image = EPUBExporter.markdownImageToken(in: chars, at: index) {
        if let resource = imageCatalog.resource(forMarkdownImageSource: image.source),
          let embedded = embeddedImage(for: resource)
        {
          flush()
          result += drawingRun(embedded, altText: image.altText)
        } else if let href = MarkdownWebURL.normalizedString(from: image.source),
          let relationshipID = hyperlinkRelationshipID(for: href)
        {
          flush()
          let label =
            image.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? image.source
            : image.altText
          var linkStyle = style
          linkStyle.hyperlink = true
          result +=
            "<w:hyperlink r:id=\"\(relationshipID)\">\(inlineRuns(label, style: linkStyle))</w:hyperlink>"
        } else {
          pending += "![\(image.altText)](\(image.source))"
        }
        index = image.end
        continue
      }

      if c == "[" {
        if let textEnd = findClose(chars: chars, start: index + 1, marker: "]"),
          textEnd + 1 < chars.count, chars[textEnd + 1] == "(",
          let urlEnd = findClose(chars: chars, start: textEnd + 2, marker: ")")
        {
          let label = String(chars[(index + 1)..<textEnd])
          let url = String(chars[(textEnd + 2)..<urlEnd])
          if let href = MarkdownWebURL.normalizedString(from: url),
            let relationshipID = hyperlinkRelationshipID(for: href)
          {
            flush()
            var linkStyle = style
            linkStyle.hyperlink = true
            result +=
              "<w:hyperlink r:id=\"\(relationshipID)\">\(inlineRuns(label, style: linkStyle))</w:hyperlink>"
          } else {
            flush()
            result += inlineRuns(label, style: style)
          }
          index = urlEnd + 1
          continue
        }
      }

      if c == "\n" {
        flush()
        result += "<w:r><w:br/></w:r>"
        index += 1
        continue
      }

      pending.append(c)
      index += 1
    }
    flush()
    return result
  }

  private func textRun(_ text: String, style: RunStyle) -> String {
    guard !text.isEmpty else { return "" }
    var properties = ""
    if style.hyperlink {
      properties += "<w:rStyle w:val=\"Hyperlink\"/>"
    }
    if style.code {
      properties += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>"
    }
    if style.bold {
      properties += "<w:b/>"
    }
    if style.italic {
      properties += "<w:i/>"
    }
    if style.strike {
      properties += "<w:strike/>"
    }
    if style.code {
      properties += "<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/>"
      properties += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F6F8FA\"/>"
    }
    let runProperties = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
    return "<w:r>\(runProperties)<w:t xml:space=\"preserve\">\(xmlEscaped(text))</w:t></w:r>"
  }

  private func metaRun(_ text: String) -> String {
    """
    <w:r><w:rPr><w:color w:val="57606A"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr>\
    <w:t xml:space="preserve">\(xmlEscaped(text))</w:t></w:r>
    """
  }

  // MARK: - Images

  private func embeddedImage(for resource: EPUBExporter.ImageResource) -> EmbeddedImage? {
    if let cached = embeddedImagesByHref[resource.href] {
      return cached
    }
    let embedded = makeEmbeddedImage(for: resource)
    embeddedImagesByHref[resource.href] = embedded
    return embedded
  }

  private func makeEmbeddedImage(for resource: EPUBExporter.ImageResource) -> EmbeddedImage? {
    guard let normalized = wordCompatibleImage(for: resource) else { return nil }

    let pixelWidth = max(1, normalized.width)
    let pixelHeight = max(1, normalized.height)
    var widthEMU = pixelWidth * Self.emuPerPixel
    var heightEMU = pixelHeight * Self.emuPerPixel
    if widthEMU > Self.maxImageWidthEMU {
      heightEMU = heightEMU * Self.maxImageWidthEMU / widthEMU
      widthEMU = Self.maxImageWidthEMU
    }
    if heightEMU > Self.maxImageHeightEMU {
      widthEMU = widthEMU * Self.maxImageHeightEMU / heightEMU
      heightEMU = Self.maxImageHeightEMU
    }
    widthEMU = max(1, widthEMU)
    heightEMU = max(1, heightEMU)

    let filename = "image\(mediaFiles.count + 1).\(normalized.fileExtension)"
    mediaFiles.append((filename: filename, data: normalized.data))
    let relationshipID = addRelationship(
      type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
      target: "media/\(filename)",
      isExternal: false)
    return EmbeddedImage(
      relationshipID: relationshipID,
      widthEMU: widthEMU,
      heightEMU: heightEMU)
  }

  private func wordCompatibleImage(for resource: EPUBExporter.ImageResource)
    -> (data: Data, fileExtension: String, width: Int, height: Int)?
  {
    let supportedExtensions: [String: String] = [
      "image/png": "png",
      "image/jpeg": "jpg",
      "image/gif": "gif",
      "image/bmp": "bmp",
      "image/tiff": "tif",
    ]

    if let fileExtension = supportedExtensions[resource.mediaType] {
      if let width = resource.width, let height = resource.height, width > 0, height > 0 {
        return (resource.data, fileExtension, width, height)
      }
      if let image = UIImage(data: resource.data) {
        return (
          resource.data,
          fileExtension,
          Int((image.size.width * image.scale).rounded()),
          Int((image.size.height * image.scale).rounded())
        )
      }
      return (resource.data, fileExtension, 600, 400)
    }

    // Formats Word cannot display (WebP, HEIC, SVG, …) are re-encoded as PNG when possible.
    guard let image = UIImage(data: resource.data), let png = image.pngData() else {
      return nil
    }
    return (
      png,
      "png",
      Int((image.size.width * image.scale).rounded()),
      Int((image.size.height * image.scale).rounded())
    )
  }

  private func drawingRun(_ image: EmbeddedImage, altText: String) -> String {
    drawingCount += 1
    let id = drawingCount
    let name = xmlEscaped("Image \(id)")
    let description = xmlEscaped(altText)
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

  private func hyperlinkRelationshipID(for url: String) -> String? {
    guard let target = MarkdownWebURL.url(from: url)?.absoluteString else { return nil }
    if let existing = hyperlinkIDsByURL[target] {
      return existing
    }
    let id = addRelationship(
      type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
      target: target,
      isExternal: true)
    hyperlinkIDsByURL[target] = id
    return id
  }

  private func addRelationship(type: String, target: String, isExternal: Bool) -> String {
    nextRelationshipIndex += 1
    let id = "rId\(nextRelationshipIndex)"
    relationships.append(
      Relationship(id: id, type: type, target: target, isExternal: isExternal))
    return id
  }

  // MARK: - Packaging

  func archive(documentTitle: String, conversation: Conversation) -> Data {
    let document = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
      xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">\
      <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" \
      w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
      """

    let documentRelationships = ([
      Relationship(
        id: "rId1",
        type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles",
        target: "styles.xml",
        isExternal: false)
    ] + relationships).map { relationship in
      var xml =
        "<Relationship Id=\"\(relationship.id)\" Type=\"\(relationship.type)\" "
        + "Target=\"\(xmlEscaped(relationship.target))\""
      if relationship.isExternal {
        xml += " TargetMode=\"External\""
      }
      xml += "/>"
      return xml
    }.joined()

    let documentRels = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
      \(documentRelationships)</Relationships>
      """

    let packageRels = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
      <Relationship Id="rId1" \
      Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
      Target="word/document.xml"/>\
      <Relationship Id="rId2" \
      Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" \
      Target="docProps/core.xml"/>\
      <Relationship Id="rId3" \
      Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" \
      Target="docProps/app.xml"/></Relationships>
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
      <Override PartName="/word/document.xml" \
      ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
      <Override PartName="/word/styles.xml" \
      ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
      <Override PartName="/docProps/core.xml" \
      ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
      <Override PartName="/docProps/app.xml" \
      ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
      """

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]
    isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    let coreProperties = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <cp:coreProperties \
      xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
      xmlns:dc="http://purl.org/dc/elements/1.1/" \
      xmlns:dcterms="http://purl.org/dc/terms/" \
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
      <dc:title>\(xmlEscaped(documentTitle))</dc:title>\
      <dcterms:created xsi:type="dcterms:W3CDTF">\(isoFormatter.string(from: conversation.createdAt))</dcterms:created>\
      <dcterms:modified xsi:type="dcterms:W3CDTF">\(isoFormatter.string(from: conversation.updatedAt))</dcterms:modified>\
      </cp:coreProperties>
      """

    let appProperties = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Properties \
      xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
      xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\
      <Application>PocketMai</Application></Properties>
      """

    var zip = StoredZipArchive()
    zip.addFile(path: "[Content_Types].xml", data: Data(contentTypes.utf8))
    zip.addFile(path: "_rels/.rels", data: Data(packageRels.utf8))
    zip.addFile(path: "docProps/core.xml", data: Data(coreProperties.utf8))
    zip.addFile(path: "docProps/app.xml", data: Data(appProperties.utf8))
    zip.addFile(path: "word/document.xml", data: Data(document.utf8))
    zip.addFile(path: "word/styles.xml", data: Data(Self.stylesXML.utf8))
    zip.addFile(path: "word/_rels/document.xml.rels", data: Data(documentRels.utf8))
    for media in mediaFiles {
      zip.addFile(path: "word/media/\(media.filename)", data: media.data)
    }
    return zip.data()
  }

  // MARK: - XML helpers

  private func paragraph(_ properties: String, _ runs: String) -> String {
    let paragraphProperties = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
    return "<w:p>\(paragraphProperties)\(runs)</w:p>"
  }

  private func paragraphProperties(
    style: String? = nil,
    border: String? = nil,
    indentLeft: Int? = nil,
    hanging: Int? = nil,
    alignment: String? = nil
  ) -> String {
    var xml = ""
    if let style {
      xml += "<w:pStyle w:val=\"\(style)\"/>"
    }
    if let border {
      xml += border
    }
    if indentLeft != nil || hanging != nil {
      xml += "<w:ind"
      if let indentLeft {
        xml += " w:left=\"\(indentLeft)\""
      }
      if let hanging {
        xml += " w:hanging=\"\(hanging)\""
      }
      xml += "/>"
    }
    if let alignment {
      xml += "<w:jc w:val=\"\(alignment)\"/>"
    }
    return xml
  }

  private func findClose(chars: [Character], start: Int, marker: String) -> Int? {
    let markerChars = Array(marker)
    guard !markerChars.isEmpty, start <= chars.count else { return nil }
    var i = start
    while i + markerChars.count <= chars.count {
      if chars[i] == "\\" {
        i += 2
        continue
      }
      var matched = true
      for (offset, mc) in markerChars.enumerated() where chars[i + offset] != mc {
        matched = false
        break
      }
      if matched {
        return i
      }
      i += 1
    }
    return nil
  }

  private func xmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr>\
    </w:rPrDefault><w:pPrDefault><w:pPr>\
    <w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
    </w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal">\
    <w:name w:val="Normal"/><w:qFormat/></w:style>\
    <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">\
    <w:name w:val="Default Paragraph Font"/></w:style>\
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/>\
    <w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:spacing w:before="480" w:after="240"/><w:jc w:val="center"/></w:pPr>\
    <w:rPr><w:b/><w:sz w:val="48"/><w:szCs w:val="48"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>\
    <w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>\
    <w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/>\
    <w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr>\
    <w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/>\
    <w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr>\
    <w:rPr><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/>\
    <w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="3"/></w:pPr>\
    <w:rPr><w:b/><w:sz w:val="23"/><w:szCs w:val="23"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/>\
    <w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="4"/></w:pPr>\
    <w:rPr><w:b/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/>\
    <w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="5"/></w:pPr>\
    <w:rPr><w:b/><w:i/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/>\
    <w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:pBdr><w:left w:val="single" w:sz="12" w:space="4" w:color="D0D7DE"/></w:pBdr></w:pPr>\
    <w:rPr><w:color w:val="57606A"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/>\
    <w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F6F8FA"/>\
    <w:spacing w:before="120" w:after="160" w:line="240" w:lineRule="auto"/></w:pPr>\
    <w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/>\
    <w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/>\
    <w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:spacing w:after="240"/></w:pPr>\
    <w:rPr><w:i/><w:color w:val="57606A"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>\
    <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>\
    <w:basedOn w:val="DefaultParagraphFont"/>\
    <w:rPr><w:color w:val="0969DA"/><w:u w:val="single"/></w:rPr></w:style>\
    </w:styles>
    """
}
