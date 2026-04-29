import Foundation

enum EPUBExporter {
  static func makeEPUB(conversation: Conversation) -> Data {
    let title = conversation.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let bookTitle = title.isEmpty ? "Chat" : title
    let identifier = "urn:uuid:\(conversation.id.uuidString.lowercased())"
    let modified = epubModifiedDate(conversation.updatedAt)
    let chatTitle = xmlEscaped(bookTitle)

    let container = """
      <?xml version="1.0" encoding="UTF-8"?>
      <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
          <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles>
      </container>
      """

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
          <item id="chat" href="chat.xhtml" media-type="application/xhtml+xml"/>
          <item id="style" href="styles.css" media-type="text/css"/>
        </manifest>
        <spine>
          <itemref idref="chat"/>
        </spine>
      </package>
      """

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
          <h1>\(chatTitle)</h1>
          <ol>
            <li><a href="chat.xhtml">Conversation</a></li>
          </ol>
        </nav>
      </body>
      </html>
      """

    let chat = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE html>
      <html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>\(chatTitle)</title>
        <link rel="stylesheet" type="text/css" href="styles.css"/>
      </head>
      <body>
        <h1>\(chatTitle)</h1>
      \(conversation.messages.enumerated().map(messageSection).joined(separator: "\n"))
      </body>
      </html>
      """

    let css = """
      body {
        color: #1f2328;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        line-height: 1.5;
        margin: 5%;
      }
      h1 {
        font-size: 1.7em;
        margin-bottom: 1.4em;
      }
      section {
        border-top: 1px solid #d0d7de;
        margin-top: 1.5em;
        padding-top: 1em;
      }
      h2 {
        color: #57606a;
        font-size: 1em;
        margin: 0 0 0.6em;
      }
      p {
        margin: 0.7em 0;
        white-space: normal;
      }
      pre {
        background: #f6f8fa;
        border-radius: 6px;
        overflow-wrap: break-word;
        padding: 0.8em;
        white-space: pre-wrap;
      }
      """

    var archive = StoredZipArchive()
    archive.addFile(path: "mimetype", data: Data("application/epub+zip".utf8))
    archive.addFile(path: "META-INF/container.xml", data: Data(container.utf8))
    archive.addFile(path: "OEBPS/content.opf", data: Data(contentOPF.utf8))
    archive.addFile(path: "OEBPS/nav.xhtml", data: Data(nav.utf8))
    archive.addFile(path: "OEBPS/chat.xhtml", data: Data(chat.utf8))
    archive.addFile(path: "OEBPS/styles.css", data: Data(css.utf8))
    return archive.data()
  }

  private static func epubModifiedDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  private static func messageSection(offset: Int, element: ChatMessage) -> String {
    let heading = xmlEscaped(element.role.displayName)
    let body = htmlBody(from: element.text)
    return """
        <section id="message-\(offset + 1)">
          <h2>\(heading)</h2>
      \(body)
        </section>
      """
  }

  private static func htmlBody(from text: String) -> String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return "    <p></p>"
    }

    let blocks = normalized.components(separatedBy: "\n\n")
    return blocks.map { block in
      let escaped = xmlEscaped(block).replacingOccurrences(of: "\n", with: "<br/>")
      return "    <p>\(escaped)</p>"
    }.joined(separator: "\n")
  }

  private static func xmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
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
