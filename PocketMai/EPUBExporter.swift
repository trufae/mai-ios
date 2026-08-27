import Foundation
import SwiftUI
import UIKit

enum EPUBExporter {
  typealias ImageResource = ConversationExportContent.ImageResource
  typealias ImageResourceCatalog = ConversationExportContent.ImageResourceCatalog
  typealias MessageContent = ConversationExportContent.MessageContent

  static func makeEPUB(
    conversation: Conversation,
    includeThinking: Bool? = nil,
    imageSize: AttachmentImageSize = .full
  ) async throws -> Data {
    let summary = ConversationExportContent.summary(for: conversation)
    let identifier = "urn:uuid:\(conversation.id.uuidString.lowercased())"
    let modified = epubModifiedDate(conversation.updatedAt)
    let chatTitle = xmlEscaped(summary.title)
    let shouldIncludeThinking = includeThinking ?? conversation.showThinking

    let imageCatalog = try await ConversationExportContent.buildImageResourceCatalog(
      conversation: conversation,
      includeThinking: shouldIncludeThinking,
      imageSize: imageSize)

    let chapters = buildChapters(
      conversation: conversation,
      summary: summary,
      includeThinking: shouldIncludeThinking,
      imageCatalog: imageCatalog)

    let container = """
      <?xml version="1.0" encoding="UTF-8"?>
      <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
          <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles>
      </container>
      """

    let chapterManifestEntries = chapters.map { chapter in
      "    <item id=\"\(chapter.id)\" href=\"\(chapter.filename)\" media-type=\"application/xhtml+xml\"/>"
    }.joined(separator: "\n")

    let imageManifestEntries = imageCatalog.resources.map { resource in
      """
          <item id="\(resource.id)" href="\(xmlEscaped(resource.href))" media-type="\(xmlEscaped(resource.mediaType))"/>
      """
    }.joined(separator: "\n")

    let manifestEntries = ([chapterManifestEntries, imageManifestEntries])
      .filter { !$0.isEmpty }
      .joined(separator: "\n")

    let spineEntries = chapters.map { chapter in
      "    <itemref idref=\"\(chapter.id)\"/>"
    }.joined(separator: "\n")

    let contentOPF = """
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="bookid">\(xmlEscaped(identifier))</dc:identifier>
          <dc:title>\(chatTitle)</dc:title>
          <dc:language>en</dc:language>
          <meta property="dcterms:modified">\(modified)</meta>
        </metadata>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="style" href="styles.css" media-type="text/css"/>
      \(manifestEntries)
        </manifest>
        <spine>
      \(spineEntries)
        </spine>
      </package>
      """

    let tocItems = chapters.map { chapter in
      "          <li><a href=\"\(chapter.filename)\">\(xmlEscaped(chapter.tocTitle))</a></li>"
    }.joined(separator: "\n")

    let nav = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE html>
      <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>\(chatTitle)</title>
        <link rel="stylesheet" type="text/css" href="styles.css"/>
      </head>
      <body>
        <nav epub:type="toc" id="toc">
          <h1>Table of Contents</h1>
          <ol>
      \(tocItems)
          </ol>
        </nav>
      </body>
      </html>
      """

    var archive = StoredZipArchive()
    archive.addFile(path: "mimetype", data: Data("application/epub+zip".utf8))
    archive.addFile(path: "META-INF/container.xml", data: Data(container.utf8))
    archive.addFile(path: "OEBPS/content.opf", data: Data(contentOPF.utf8))
    archive.addFile(path: "OEBPS/nav.xhtml", data: Data(nav.utf8))
    archive.addFile(path: "OEBPS/styles.css", data: Data(stylesCSS.utf8))
    for chapter in chapters {
      archive.addFile(path: "OEBPS/\(chapter.filename)", data: Data(chapter.xhtml.utf8))
    }
    for resource in imageCatalog.resources {
      archive.addFile(path: "OEBPS/\(resource.href)", data: resource.data)
    }
    return archive.data()
  }

  // MARK: - Chapters

  private struct Chapter {
    let id: String
    let filename: String
    let tocTitle: String
    let xhtml: String
  }

  private static func buildChapters(
    conversation: Conversation,
    summary: ConversationExportContent.ConversationSummary,
    includeThinking: Bool,
    imageCatalog: ImageResourceCatalog
  ) -> [Chapter] {
    var chapters: [Chapter] = []
    chapters.append(makeTitleChapter(summary: summary))

    var exportedMessageCount = 0
    for message in conversation.messages {
      let content = ConversationExportContent.messageContent(
        for: message,
        includeThinking: includeThinking)
      guard content.hasExportedBody || imageCatalog.hasImageAttachments(for: message) else {
        continue
      }

      exportedMessageCount += 1
      let id = String(format: "msg%03d", exportedMessageCount)
      let blocks = MarkdownParser.blocks(from: content.visibleText)
      let textSnippet = chapterSnippet(blocks: blocks)
      let snippet =
        textSnippet.isEmpty
        ? imageCatalog.firstImageAttachmentDisplayName(in: message) ?? ""
        : textSnippet
      let displayRole = message.role.displayName
      let tocTitle: String
      if snippet.isEmpty {
        tocTitle = "\(exportedMessageCount). \(displayRole)"
      } else {
        tocTitle = "\(exportedMessageCount). \(displayRole) — \(snippet)"
      }

      let bodyHTML = htmlForMessageContent(
        content,
        visibleBlocks: blocks,
        message: message,
        imageCatalog: imageCatalog)

      let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
        <head>
          <meta charset="utf-8"/>
          <title>\(xmlEscaped(tocTitle))</title>
          <link rel="stylesheet" type="text/css" href="styles.css"/>
        </head>
        <body>
          <section class="message role-\(message.role.rawValue)" id="\(id)">
            <h1 class="role">\(xmlEscaped(displayRole))</h1>
              \(bodyHTML)
          </section>
        </body>
        </html>
        """

      chapters.append(
        Chapter(id: id, filename: "\(id).xhtml", tocTitle: tocTitle, xhtml: xhtml)
      )
    }

    return chapters
  }

  private static func makeTitleChapter(
    summary: ConversationExportContent.ConversationSummary
  ) -> Chapter {
    let xhtml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE html>
      <html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>\(xmlEscaped(summary.title))</title>
        <link rel="stylesheet" type="text/css" href="styles.css"/>
      </head>
      <body>
        <section class="title-page">
          <h1>\(xmlEscaped(summary.title))</h1>
          <p class="meta">Started \(xmlEscaped(summary.started))</p>
          <p class="meta">Last updated \(xmlEscaped(summary.lastUpdated))</p>
          <p class="meta">\(xmlEscaped(summary.messageCountText))</p>
        </section>
      </body>
      </html>
      """

    return Chapter(id: "title", filename: "title.xhtml", tocTitle: summary.title, xhtml: xhtml)
  }

  private static func chapterSnippet(blocks: [MarkdownBlock]) -> String {
    for block in blocks {
      switch block.kind {
      case .heading(_, let text):
        return truncateSnippet(stripInlineMarkdown(text))
      case .text(let value):
        let firstLine =
          value
          .components(separatedBy: .newlines)
          .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let stripped = stripInlineMarkdown(firstLine.trimmingCharacters(in: .whitespaces))
        if !stripped.isEmpty {
          return truncateSnippet(stripped)
        }
      case .blockquote(let value):
        let firstLine =
          value
          .components(separatedBy: .newlines)
          .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let stripped = stripInlineMarkdown(firstLine.trimmingCharacters(in: .whitespaces))
        if !stripped.isEmpty {
          return truncateSnippet(stripped)
        }
      case .bulletList(let items):
        if let first = items.first {
          return truncateSnippet(stripInlineMarkdown(first))
        }
      case .orderedList(let items):
        if let first = items.first {
          return truncateSnippet(stripInlineMarkdown(first.text))
        }
      case .taskList(let items):
        if let first = items.first {
          return truncateSnippet(stripInlineMarkdown(first.text))
        }
      case .mermaid:
        return "Mermaid diagram"
      case .horizontalRule, .table, .code, .footnotes:
        continue
      }
    }
    return ""
  }

  private static func truncateSnippet(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let limit = 60
    if trimmed.count <= limit { return trimmed }
    let endIndex = trimmed.index(trimmed.startIndex, offsetBy: limit)
    return trimmed[..<endIndex].trimmingCharacters(in: .whitespaces) + "…"
  }

  // MARK: - Block rendering

  private static func htmlForMessageContent(
    _ content: MessageContent,
    visibleBlocks: [MarkdownBlock],
    message: ChatMessage,
    imageCatalog: ImageResourceCatalog
  ) -> String {
    var parts: [String] = []
    for section in content.reasoningSections {
      let blocks = MarkdownParser.blocks(from: section)
      let body =
        blocks.isEmpty
        ? "<p></p>"
        : blocks.map { htmlForBlock($0, imageCatalog: imageCatalog) }
          .joined(separator: "\n        ")
      parts.append(
        """
        <section class="reasoning">
          <h2>Reasoning</h2>
          \(body)
        </section>
        """
      )
    }

    if !content.visibleText.isEmpty {
      parts.append(
        visibleBlocks.map { htmlForBlock($0, imageCatalog: imageCatalog) }
          .joined(separator: "\n      "))
    }

    let attachmentHTML = imageAttachmentsHTML(for: message, imageCatalog: imageCatalog)
    if !attachmentHTML.isEmpty {
      parts.append(attachmentHTML)
    }

    return parts.isEmpty ? "<p></p>" : parts.joined(separator: "\n      ")
  }

  private static func htmlForBlock(_ block: MarkdownBlock, imageCatalog: ImageResourceCatalog)
    -> String
  {
    switch block.kind {
    case .heading(let level, let text):
      let tag = "h\(min(6, max(2, level + 1)))"
      return "<\(tag)>\(inlineHTML(text, imageCatalog: imageCatalog))</\(tag)>"
    case .text(let value):
      return paragraphsHTML(value, imageCatalog: imageCatalog)
    case .blockquote(let value):
      return "<blockquote>\(paragraphsHTML(value, imageCatalog: imageCatalog))</blockquote>"
    case .horizontalRule:
      return "<hr/>"
    case .code(let language, let code):
      let attr = language.isEmpty ? "" : " class=\"language-\(xmlEscaped(language))\""
      return "<pre><code\(attr)>\(highlightedCodeHTML(code, language: language))</code></pre>"
    case .mermaid(let source):
      if let resource = imageCatalog.resource(forMermaidDiagram: source) {
        var imageAttributes =
          "src=\"\(xmlEscaped(resource.href))\" alt=\"Mermaid diagram\""
        if let width = resource.width, width > 0 {
          imageAttributes += " width=\"\(width)\""
        }
        if let height = resource.height, height > 0 {
          imageAttributes += " height=\"\(height)\""
        }
        return """
          <figure class="mermaid-diagram">
            <img \(imageAttributes)/>
          </figure>
          """
      }
      return """
        <pre><code class="language-mermaid">\(highlightedCodeHTML(source, language: "mermaid"))</code></pre>
        """
    case .table(let headers, let rows, let alignments):
      return tableHTML(
        headers: headers,
        rows: rows,
        alignments: alignments,
        imageCatalog: imageCatalog)
    case .taskList(let items):
      let lis = items.map { item -> String in
        let mark = item.checked ? "&#9745;" : "&#9744;"
        return "<li>\(mark) \(inlineHTML(item.text, imageCatalog: imageCatalog))</li>"
      }.joined()
      return "<ul class=\"task-list\">\(lis)</ul>"
    case .bulletList(let items):
      let lis = items.map { "<li>\(inlineHTML($0, imageCatalog: imageCatalog))</li>" }.joined()
      return "<ul>\(lis)</ul>"
    case .orderedList(let items):
      let lis = items.map {
        "<li value=\"\($0.number)\">\(inlineHTML($0.text, imageCatalog: imageCatalog))</li>"
      }.joined()
      return "<ol>\(lis)</ol>"
    case .footnotes(let items):
      let lis = items.map { item -> String in
        let sup = MarkdownInlineSymbols.toSuperscript(item.key)
        return "<li>\(sup) \(inlineHTML(item.text, imageCatalog: imageCatalog))</li>"
      }.joined()
      return "<hr/><ol class=\"footnotes\">\(lis)</ol>"
    }
  }

  private static func paragraphsHTML(_ text: String, imageCatalog: ImageResourceCatalog) -> String {
    text.components(separatedBy: "\n\n").compactMap { para -> String? in
      let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if trimmed.hasPrefix("> ") || trimmed.hasPrefix(">") {
        return blockquoteHTML(trimmed, imageCatalog: imageCatalog)
      }
      let lines = trimmed.components(separatedBy: "\n")
      let html = lines.map { inlineHTML($0, imageCatalog: imageCatalog) }
        .joined(separator: "<br/>")
      return "<p>\(html)</p>"
    }.joined(separator: "\n      ")
  }

  private static func blockquoteHTML(_ text: String, imageCatalog: ImageResourceCatalog) -> String {
    let inner = text.components(separatedBy: "\n").map { line -> String in
      var trimmed = line
      if trimmed.hasPrefix("> ") {
        trimmed.removeFirst(2)
      } else if trimmed.hasPrefix(">") {
        trimmed.removeFirst()
      }
      return inlineHTML(trimmed, imageCatalog: imageCatalog)
    }.joined(separator: "<br/>")
    return "<blockquote><p>\(inner)</p></blockquote>"
  }

  private static func tableHTML(
    headers: [String],
    rows: [[String]],
    alignments: [TextAlignment],
    imageCatalog: ImageResourceCatalog
  ) -> String {
    func alignAttr(_ index: Int) -> String {
      guard index < alignments.count else { return "" }
      switch alignments[index] {
      case .center: return " style=\"text-align:center\""
      case .trailing: return " style=\"text-align:right\""
      default: return ""
      }
    }
    let head =
      "<thead><tr>"
      + headers.enumerated().map { index, value in
        "<th\(alignAttr(index))>\(inlineHTML(value, imageCatalog: imageCatalog))</th>"
      }.joined()
      + "</tr></thead>"
    let body =
      "<tbody>"
      + rows.map { row in
        "<tr>"
          + row.enumerated().map { index, cell in
            "<td\(alignAttr(index))>\(inlineHTML(cell, imageCatalog: imageCatalog))</td>"
          }.joined()
          + "</tr>"
      }.joined()
      + "</tbody>"
    return "<table>\(head)\(body)</table>"
  }

  private static func imageAttachmentsHTML(
    for message: ChatMessage,
    imageCatalog: ImageResourceCatalog
  ) -> String {
    let figures = message.attachments.compactMap { attachment -> String? in
      guard attachment.kind == .image,
        let resource = imageCatalog.resource(for: attachment)
      else {
        return nil
      }

      var imageAttributes =
        "src=\"\(xmlEscaped(resource.href))\" alt=\"\(xmlEscaped(attachment.displayName))\""
      if let width = resource.width, width > 0 {
        imageAttributes += " width=\"\(width)\""
      }
      if let height = resource.height, height > 0 {
        imageAttributes += " height=\"\(height)\""
      }
      return """
        <figure class="attachment-image">
          <img \(imageAttributes)/>
          <figcaption>\(xmlEscaped(attachment.displayName))</figcaption>
        </figure>
        """
    }
    guard !figures.isEmpty else { return "" }
    return """
      <section class="attachments">
        \(figures.joined(separator: "\n        "))
      </section>
      """
  }

  // MARK: - Inline rendering

  private static func inlineHTML(_ raw: String, imageCatalog: ImageResourceCatalog) -> String {
    inlineHTML(ConversationExportContent.inlineNodes(raw), imageCatalog: imageCatalog)
  }

  private static func inlineHTML(
    _ nodes: [ConversationExportContent.MarkdownInlineNode],
    imageCatalog: ImageResourceCatalog
  ) -> String {
    nodes.map { node -> String in
      switch node {
      case .text(let value):
        return xmlEscaped(value)
      case .lineBreak:
        return "<br/>"
      case .code(let code):
        return inlineCodeHTML(code)
      case .emphasis(let children):
        return "<em>\(inlineHTML(children, imageCatalog: imageCatalog))</em>"
      case .strong(let children):
        return "<strong>\(inlineHTML(children, imageCatalog: imageCatalog))</strong>"
      case .strikethrough(let children):
        return "<del>\(inlineHTML(children, imageCatalog: imageCatalog))</del>"
      case .link(let label, let url):
        return "<a href=\"\(xmlEscaped(url))\">\(inlineHTML(label, imageCatalog: imageCatalog))</a>"
      case .image(let altText, let source):
        if let src = imageCatalog.href(forMarkdownImageSource: source) {
          return "<img src=\"\(xmlEscaped(src))\" alt=\"\(xmlEscaped(altText))\"/>"
        }
        if let href = MarkdownWebURL.normalizedString(from: source) {
          let label =
            altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? source : altText
          let labelHTML = inlineHTML(label, imageCatalog: imageCatalog)
          return "<a href=\"\(xmlEscaped(href))\">\(labelHTML)</a>"
        }
        return xmlEscaped("![\(altText)](\(source))")
      }
    }.joined()
  }

  private static func inlineCodeHTML(_ code: String) -> String {
    if let href = MarkdownWebURL.normalizedString(from: code) {
      return "<a href=\"\(xmlEscaped(href))\"><code>\(xmlEscaped(code))</code></a>"
    }
    return "<code>\(xmlEscaped(code))</code>"
  }

  private static func highlightedCodeHTML(_ code: String, language: String) -> String {
    let chars = Array(code)
    var result = ""
    var index = 0

    while index < chars.count {
      let c = chars[index]

      if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
        let start = index
        index += 2
        var closed = false
        while index + 1 < chars.count {
          if chars[index] == "*", chars[index + 1] == "/" {
            index += 2
            closed = true
            break
          }
          index += 1
        }
        if !closed {
          index = chars.count
        }
        result += syntaxSpan("comment", String(chars[start..<index]))
        continue
      }

      if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
        let start = index
        index += 2
        while index < chars.count, chars[index] != "\n" {
          index += 1
        }
        result += syntaxSpan("comment", String(chars[start..<index]))
        continue
      }

      if c == "#", isLineLeadingComment(in: chars, at: index, language: language) {
        let start = index
        index += 1
        while index < chars.count, chars[index] != "\n" {
          index += 1
        }
        result += syntaxSpan("comment", String(chars[start..<index]))
        continue
      }

      if c == "\"", index + 1 < chars.count, chars[index + 1] == "\"",
        index + 2 < chars.count, chars[index + 2] == "\""
      {
        let start = index
        index += 3
        var closed = false
        while index + 2 < chars.count {
          if chars[index] == "\"", chars[index + 1] == "\"", chars[index + 2] == "\"" {
            index += 3
            closed = true
            break
          }
          index += 1
        }
        if !closed {
          index = chars.count
        }
        result += syntaxSpan("string", String(chars[start..<index]))
        continue
      }

      if c == "\"" || c == "'" {
        let start = index
        let quote = c
        index += 1
        var escaped = false
        while index < chars.count {
          let next = chars[index]
          index += 1
          if escaped {
            escaped = false
          } else if next == "\\" {
            escaped = true
          } else if next == quote || next == "\n" {
            break
          }
        }
        result += syntaxSpan("string", String(chars[start..<index]))
        continue
      }

      if c.isNumber {
        let start = index
        index += 1
        while index < chars.count, isNumberBody(chars[index]) {
          index += 1
        }
        result += syntaxSpan("number", String(chars[start..<index]))
        continue
      }

      if c.isLetter || c == "_" {
        let start = index
        index += 1
        while index < chars.count, isIdentifierBody(chars[index]) {
          index += 1
        }
        let token = String(chars[start..<index])
        if syntaxKeywords.contains(token) {
          result += syntaxSpan("keyword", token)
        } else {
          result += xmlEscaped(token)
        }
        continue
      }

      result += xmlEscaped(String(c))
      index += 1
    }

    return result
  }

  private static func syntaxSpan(_ className: String, _ value: String) -> String {
    "<span class=\"syntax-\(className)\">\(xmlEscaped(value))</span>"
  }

  private static func isLineLeadingComment(
    in chars: [Character], at index: Int, language: String
  ) -> Bool {
    let commentLanguages: Set<String> = [
      "bash", "conf", "fish", "make", "makefile", "py", "python", "rb", "ruby", "sh", "shell",
      "toml", "yaml", "yml", "zsh",
    ]
    let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedLanguage.isEmpty || commentLanguages.contains(normalizedLanguage) else {
      return false
    }
    var cursor = index
    while cursor > 0 {
      cursor -= 1
      if chars[cursor] == "\n" {
        return true
      }
      if chars[cursor] != " " && chars[cursor] != "\t" {
        return false
      }
    }
    return true
  }

  private static func isIdentifierBody(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }

  private static func isNumberBody(_ character: Character) -> Bool {
    character.isNumber || character == "." || character == "_" || character == "x"
      || character == "X"
      || character == "a" || character == "b" || character == "c" || character == "d"
      || character == "e" || character == "f" || character == "A" || character == "B"
      || character == "C" || character == "D" || character == "E" || character == "F"
  }

  private static func stripInlineMarkdown(_ raw: String) -> String {
    plainText(of: ConversationExportContent.inlineNodes(raw))
      .trimmingCharacters(in: .whitespaces)
  }

  private static func plainText(
    of nodes: [ConversationExportContent.MarkdownInlineNode]
  ) -> String {
    nodes.map { node -> String in
      switch node {
      case .text(let value):
        return value
      case .lineBreak:
        return "\n"
      case .code(let code):
        return code
      case .emphasis(let children), .strong(let children), .strikethrough(let children),
        .link(let children, _):
        return plainText(of: children)
      case .image(let altText, _):
        return plainText(of: ConversationExportContent.inlineNodes(altText))
      }
    }.joined()
  }

  // MARK: - Utilities

  private static func epubModifiedDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  private static func xmlEscaped(_ value: String) -> String {
    ConversationExportContent.xmlEscaped(value)
  }

  private static let syntaxKeywords: Set<String> = [
    "actor", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
    "default", "defer", "do", "else", "enum", "export", "extends", "false", "final", "for",
    "from", "func", "function", "guard", "if", "import", "in", "interface", "let", "nil", "null",
    "private", "public", "return", "self", "static", "struct", "switch", "throw", "throws", "true",
    "try", "typealias", "var", "while",
  ]

  private static let stylesCSS = """
    body {
      color: #1f2328;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.5;
      margin: 5%;
    }
    h1 { font-size: 1.7em; margin: 1em 0 0.6em; }
    h2 { font-size: 1.35em; margin: 1em 0 0.5em; }
    h3 { font-size: 1.15em; margin: 1em 0 0.4em; }
    h4, h5, h6 { font-size: 1em; margin: 1em 0 0.4em; }
    h1.role {
      color: #57606a;
      font-size: 1em;
      font-weight: 600;
      letter-spacing: 0.04em;
      margin: 0 0 1em;
      text-transform: uppercase;
    }
    .title-page { text-align: center; margin-top: 30%; }
    .title-page h1 { font-size: 2em; margin-bottom: 1em; }
    .title-page .meta { color: #57606a; font-size: 0.9em; margin: 0.2em 0; }
    section.message { margin-top: 1em; }
    section.message.role-user h1.role { color: #1a7f37; }
    section.message.role-assistant h1.role { color: #0969da; }
    section.message.role-tool h1.role { color: #8250df; }
    section.message.role-error h1.role { color: #cf222e; }
    section.reasoning {
      background: #f6f8fa;
      border-left: 3px solid #8250df;
      color: #57606a;
      margin: 0 0 1em;
      padding: 0.6em 1em;
    }
    section.reasoning h2 {
      color: #8250df;
      font-size: 0.95em;
      margin-top: 0;
      text-transform: uppercase;
    }
    p { margin: 0.7em 0; }
    pre {
      background: #f6f8fa;
      border-radius: 6px;
      overflow-wrap: break-word;
      padding: 0.8em;
      white-space: pre-wrap;
      font-family: "SF Mono", Menlo, Consolas, monospace;
      font-size: 0.9em;
    }
    code {
      background: #f6f8fa;
      border-radius: 4px;
      font-family: "SF Mono", Menlo, Consolas, monospace;
      font-size: 0.9em;
      padding: 0.1em 0.3em;
    }
    del { text-decoration: line-through; }
    pre code { background: transparent; padding: 0; }
    .syntax-keyword { color: #8250df; font-weight: 600; }
    .syntax-number { color: #bc4c00; }
    .syntax-string { color: #1a7f37; }
    .syntax-comment { color: #57606a; font-style: italic; }
    blockquote {
      border-left: 3px solid #d0d7de;
      color: #57606a;
      margin: 0.7em 0;
      padding: 0 1em;
    }
    ul, ol { padding-left: 1.6em; }
    li { margin: 0.2em 0; }
    ul.task-list { list-style: none; padding-left: 0.4em; }
    a { color: #0969da; text-decoration: underline; }
    table {
      border-collapse: collapse;
      margin: 0.8em 0;
      width: 100%;
    }
    th, td {
      border: 1px solid #d0d7de;
      padding: 0.4em 0.7em;
      text-align: left;
      vertical-align: top;
    }
    th { background: #f6f8fa; font-weight: 600; }
    img { max-width: 100%; height: auto; }
    section.attachments { margin-top: 1em; }
    figure.mermaid-diagram {
      margin: 0.9em 0;
      page-break-inside: avoid;
      text-align: left;
    }
    figure.attachment-image { margin: 0.9em 0; }
    figure.attachment-image figcaption {
      color: #57606a;
      font-size: 0.85em;
      margin-top: 0.35em;
    }
    """
}
