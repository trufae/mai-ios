import Foundation
import SwiftUI

enum EPUBExporter {
  static func makeEPUB(conversation: Conversation) -> Data {
    let title = conversation.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let bookTitle = title.isEmpty ? "Chat" : title
    let identifier = "urn:uuid:\(conversation.id.uuidString.lowercased())"
    let modified = epubModifiedDate(conversation.updatedAt)
    let chatTitle = xmlEscaped(bookTitle)

    let chapters = buildChapters(conversation: conversation, bookTitle: bookTitle)

    let container = """
      <?xml version="1.0" encoding="UTF-8"?>
      <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
          <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles>
      </container>
      """

    let manifestEntries = chapters.map { chapter in
      "    <item id=\"\(chapter.id)\" href=\"\(chapter.filename)\" media-type=\"application/xhtml+xml\"/>"
    }.joined(separator: "\n")

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
    return archive.data()
  }

  // MARK: - Chapters

  private struct Chapter {
    let id: String
    let filename: String
    let tocTitle: String
    let xhtml: String
  }

  private struct MessageContent {
    let visibleText: String
    let reasoningSections: [String]

    var hasExportedBody: Bool {
      !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || reasoningSections.contains {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
  }

  private static func buildChapters(conversation: Conversation, bookTitle: String) -> [Chapter] {
    var chapters: [Chapter] = []
    chapters.append(makeTitleChapter(conversation: conversation, bookTitle: bookTitle))

    var exportedMessageCount = 0
    for message in conversation.messages {
      let content = messageContent(for: message, includeThinking: conversation.showThinking)
      guard content.hasExportedBody else { continue }

      exportedMessageCount += 1
      let id = String(format: "msg%03d", exportedMessageCount)
      let blocks = MarkdownParser.blocks(from: content.visibleText)
      let snippet = chapterSnippet(blocks: blocks)
      let displayRole = message.role.displayName
      let tocTitle: String
      if snippet.isEmpty {
        tocTitle = "\(exportedMessageCount). \(displayRole)"
      } else {
        tocTitle = "\(exportedMessageCount). \(displayRole) — \(snippet)"
      }

      let bodyHTML = htmlForMessageContent(content, visibleBlocks: blocks)

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

  private static func messageContent(for message: ChatMessage, includeThinking: Bool)
    -> MessageContent
  {
    let rendered = MessageContentFilter.render(message.text)
    let reasoningSections =
      includeThinking
      ? rendered.hiddenSections.filter { $0.tag == "think" }.map(\.content)
      : []
    return MessageContent(visibleText: rendered.visibleText, reasoningSections: reasoningSections)
  }

  private static func makeTitleChapter(conversation: Conversation, bookTitle: String) -> Chapter {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .long
    dateFormatter.timeStyle = .short
    let created = dateFormatter.string(from: conversation.createdAt)
    let updated = dateFormatter.string(from: conversation.updatedAt)
    let messageCount = conversation.messages.count

    let xhtml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE html>
      <html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>\(xmlEscaped(bookTitle))</title>
        <link rel="stylesheet" type="text/css" href="styles.css"/>
      </head>
      <body>
        <section class="title-page">
          <h1>\(xmlEscaped(bookTitle))</h1>
          <p class="meta">Started \(xmlEscaped(created))</p>
          <p class="meta">Last updated \(xmlEscaped(updated))</p>
          <p class="meta">\(messageCount) message\(messageCount == 1 ? "" : "s")</p>
        </section>
      </body>
      </html>
      """

    return Chapter(id: "title", filename: "title.xhtml", tocTitle: bookTitle, xhtml: xhtml)
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
      case .bulletList(let items):
        if let first = items.first {
          return truncateSnippet(stripInlineMarkdown(first))
        }
      case .taskList(let items):
        if let first = items.first {
          return truncateSnippet(stripInlineMarkdown(first.text))
        }
      case .table, .code:
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
    _ content: MessageContent, visibleBlocks: [MarkdownBlock]
  ) -> String {
    var parts: [String] = []
    for section in content.reasoningSections {
      let blocks = MarkdownParser.blocks(from: section)
      let body =
        blocks.isEmpty
        ? "<p></p>"
        : blocks.map(htmlForBlock).joined(separator: "\n        ")
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
      parts.append(visibleBlocks.map(htmlForBlock).joined(separator: "\n      "))
    }

    return parts.isEmpty ? "<p></p>" : parts.joined(separator: "\n      ")
  }

  private static func htmlForBlock(_ block: MarkdownBlock) -> String {
    switch block.kind {
    case .heading(let level, let text):
      let tag = "h\(min(6, max(2, level + 1)))"
      return "<\(tag)>\(inlineHTML(text))</\(tag)>"
    case .text(let value):
      return paragraphsHTML(value)
    case .code(let language, let code):
      let attr = language.isEmpty ? "" : " class=\"language-\(xmlEscaped(language))\""
      return "<pre><code\(attr)>\(xmlEscaped(code))</code></pre>"
    case .table(let headers, let rows, let alignments):
      return tableHTML(headers: headers, rows: rows, alignments: alignments)
    case .taskList(let items):
      let lis = items.map { item -> String in
        let mark = item.checked ? "&#9745;" : "&#9744;"
        return "<li>\(mark) \(inlineHTML(item.text))</li>"
      }.joined()
      return "<ul class=\"task-list\">\(lis)</ul>"
    case .bulletList(let items):
      let lis = items.map { "<li>\(inlineHTML($0))</li>" }.joined()
      return "<ul>\(lis)</ul>"
    }
  }

  private static func paragraphsHTML(_ text: String) -> String {
    text.components(separatedBy: "\n\n").compactMap { para -> String? in
      let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if trimmed.hasPrefix("> ") || trimmed.hasPrefix(">") {
        return blockquoteHTML(trimmed)
      }
      let lines = trimmed.components(separatedBy: "\n")
      let html = lines.map(inlineHTML).joined(separator: "<br/>")
      return "<p>\(html)</p>"
    }.joined(separator: "\n      ")
  }

  private static func blockquoteHTML(_ text: String) -> String {
    let inner = text.components(separatedBy: "\n").map { line -> String in
      var trimmed = line
      if trimmed.hasPrefix("> ") {
        trimmed.removeFirst(2)
      } else if trimmed.hasPrefix(">") {
        trimmed.removeFirst()
      }
      return inlineHTML(trimmed)
    }.joined(separator: "<br/>")
    return "<blockquote><p>\(inner)</p></blockquote>"
  }

  private static func tableHTML(
    headers: [String], rows: [[String]], alignments: [TextAlignment]
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
        "<th\(alignAttr(index))>\(inlineHTML(value))</th>"
      }.joined()
      + "</tr></thead>"
    let body =
      "<tbody>"
      + rows.map { row in
        "<tr>"
          + row.enumerated().map { index, cell in
            "<td\(alignAttr(index))>\(inlineHTML(cell))</td>"
          }.joined()
          + "</tr>"
      }.joined()
      + "</tbody>"
    return "<table>\(head)\(body)</table>"
  }

  // MARK: - Inline rendering

  private static func inlineHTML(_ raw: String) -> String {
    let chars = Array(raw)
    var result = ""
    var index = 0
    while index < chars.count {
      let c = chars[index]

      if c == "\\", index + 1 < chars.count {
        let next = chars[index + 1]
        if "\\`*_{}[]()#+-.!".contains(next) {
          result += xmlEscaped(String(next))
          index += 2
          continue
        }
      }

      if c == "`" {
        if let end = findClose(chars: chars, start: index + 1, marker: "`") {
          let code = String(chars[(index + 1)..<end])
          result += "<code>\(xmlEscaped(code))</code>"
          index = end + 1
          continue
        }
      }

      if (c == "*" || c == "_") && index + 1 < chars.count && chars[index + 1] == c {
        let marker = String([c, c])
        if let end = findClose(chars: chars, start: index + 2, marker: marker) {
          let inner = String(chars[(index + 2)..<end])
          result += "<strong>\(inlineHTML(inner))</strong>"
          index = end + marker.count
          continue
        }
      }

      if c == "*" || c == "_" {
        if let end = findClose(chars: chars, start: index + 1, marker: String(c)) {
          let inner = String(chars[(index + 1)..<end])
          if !inner.isEmpty {
            result += "<em>\(inlineHTML(inner))</em>"
            index = end + 1
            continue
          }
        }
      }

      if c == "!", index + 1 < chars.count, chars[index + 1] == "[" {
        if let textEnd = findClose(chars: chars, start: index + 2, marker: "]"),
          textEnd + 1 < chars.count, chars[textEnd + 1] == "(",
          let urlEnd = findClose(chars: chars, start: textEnd + 2, marker: ")")
        {
          let alt = String(chars[(index + 2)..<textEnd])
          let url = String(chars[(textEnd + 2)..<urlEnd])
          result +=
            "<img src=\"\(xmlEscaped(url))\" alt=\"\(xmlEscaped(alt))\"/>"
          index = urlEnd + 1
          continue
        }
      }

      if c == "[" {
        if let textEnd = findClose(chars: chars, start: index + 1, marker: "]"),
          textEnd + 1 < chars.count, chars[textEnd + 1] == "(",
          let urlEnd = findClose(chars: chars, start: textEnd + 2, marker: ")")
        {
          let label = String(chars[(index + 1)..<textEnd])
          let url = String(chars[(textEnd + 2)..<urlEnd])
          result += "<a href=\"\(xmlEscaped(url))\">\(inlineHTML(label))</a>"
          index = urlEnd + 1
          continue
        }
      }

      result += xmlEscaped(String(c))
      index += 1
    }
    return result
  }

  private static func findClose(chars: [Character], start: Int, marker: String) -> Int? {
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

  private static func stripInlineMarkdown(_ raw: String) -> String {
    var result = ""
    let chars = Array(raw)
    var index = 0
    while index < chars.count {
      let c = chars[index]
      if c == "\\", index + 1 < chars.count {
        result.append(chars[index + 1])
        index += 2
        continue
      }
      if c == "`" || c == "*" || c == "_" || c == "#" {
        index += 1
        continue
      }
      if c == "[" {
        if let end = findClose(chars: chars, start: index + 1, marker: "]") {
          result += stripInlineMarkdown(String(chars[(index + 1)..<end]))
          index = end + 1
          if index < chars.count, chars[index] == "(",
            let urlEnd = findClose(chars: chars, start: index + 1, marker: ")")
          {
            index = urlEnd + 1
          }
          continue
        }
      }
      result.append(c)
      index += 1
    }
    return result.trimmingCharacters(in: .whitespaces)
  }

  // MARK: - Utilities

  private static func epubModifiedDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  private static func xmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

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
    pre code { background: transparent; padding: 0; }
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
    """
}

private struct StoredZipArchive {
  private struct Entry {
    var path: String
    var data: Data
    var crc32: UInt32
    var offset: UInt32
  }

  private var buffer = Data()
  private var entries: [Entry] = []

  mutating func addFile(path: String, data: Data) {
    guard let pathData = path.data(using: .utf8),
      data.count <= UInt32.max,
      buffer.count <= UInt32.max
    else {
      return
    }

    let crc = CRC32.checksum(data)
    let offset = UInt32(buffer.count)
    buffer.appendUInt32LE(0x0403_4b50)
    buffer.appendUInt16LE(20)
    buffer.appendUInt16LE(0)
    buffer.appendUInt16LE(0)
    buffer.appendUInt16LE(0)
    buffer.appendUInt16LE(0)
    buffer.appendUInt32LE(crc)
    buffer.appendUInt32LE(UInt32(data.count))
    buffer.appendUInt32LE(UInt32(data.count))
    buffer.appendUInt16LE(UInt16(pathData.count))
    buffer.appendUInt16LE(0)
    buffer.append(pathData)
    buffer.append(data)

    entries.append(Entry(path: path, data: data, crc32: crc, offset: offset))
  }

  func data() -> Data {
    var output = buffer
    let centralDirectoryOffset = UInt32(output.count)

    for entry in entries {
      guard let pathData = entry.path.data(using: .utf8) else { continue }
      output.appendUInt32LE(0x0201_4b50)
      output.appendUInt16LE(20)
      output.appendUInt16LE(20)
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt32LE(entry.crc32)
      output.appendUInt32LE(UInt32(entry.data.count))
      output.appendUInt32LE(UInt32(entry.data.count))
      output.appendUInt16LE(UInt16(pathData.count))
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt16LE(0)
      output.appendUInt32LE(0)
      output.appendUInt32LE(entry.offset)
      output.append(pathData)
    }

    let centralDirectorySize = UInt32(output.count) - centralDirectoryOffset
    output.appendUInt32LE(0x0605_4b50)
    output.appendUInt16LE(0)
    output.appendUInt16LE(0)
    output.appendUInt16LE(UInt16(entries.count))
    output.appendUInt16LE(UInt16(entries.count))
    output.appendUInt32LE(centralDirectorySize)
    output.appendUInt32LE(centralDirectoryOffset)
    output.appendUInt16LE(0)
    return output
  }
}

private enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { index in
    var crc = UInt32(index)
    for _ in 0..<8 {
      if crc & 1 == 1 {
        crc = (crc >> 1) ^ 0xedb8_8320
      } else {
        crc >>= 1
      }
    }
    return crc
  }

  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
      let index = Int((crc ^ UInt32(byte)) & 0xff)
      crc = (crc >> 8) ^ table[index]
    }
    return crc ^ 0xffff_ffff
  }
}

extension Data {
  fileprivate mutating func appendUInt16LE(_ value: UInt16) {
    append(UInt8(value & 0x00ff))
    append(UInt8((value >> 8) & 0x00ff))
  }

  fileprivate mutating func appendUInt32LE(_ value: UInt32) {
    append(UInt8(value & 0x0000_00ff))
    append(UInt8((value >> 8) & 0x0000_00ff))
    append(UInt8((value >> 16) & 0x0000_00ff))
    append(UInt8((value >> 24) & 0x0000_00ff))
  }
}
