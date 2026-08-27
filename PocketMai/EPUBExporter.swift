import Foundation
import SwiftUI
import UIKit

enum EPUBExporter {
  static func makeEPUB(
    conversation: Conversation,
    includeThinking: Bool? = nil,
    imageSize: AttachmentImageSize = .full
  ) async throws -> Data {
    let title = conversation.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let bookTitle = title.isEmpty ? "Chat" : title
    let identifier = "urn:uuid:\(conversation.id.uuidString.lowercased())"
    let modified = epubModifiedDate(conversation.updatedAt)
    let chatTitle = xmlEscaped(bookTitle)
    let shouldIncludeThinking = includeThinking ?? conversation.showThinking

    let imageCatalog = try await buildImageResourceCatalog(
      conversation: conversation,
      includeThinking: shouldIncludeThinking,
      imageSize: imageSize)

    let chapters = buildChapters(
      conversation: conversation,
      bookTitle: bookTitle,
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

  struct ImageResource {
    let id: String
    let href: String
    let mediaType: String
    let data: Data
    let width: Int?
    let height: Int?
  }

  struct ImageResourceCatalog {
    private(set) var resources: [ImageResource] = []
    private var attachmentHrefsByID: [UUID: String] = [:]
    private var attachmentResourcesByID: [UUID: ImageResource] = [:]
    private var remoteHrefsBySource: [String: String] = [:]
    private var remoteResourcesBySource: [String: ImageResource] = [:]
    private var mermaidResourcesBySource: [String: ImageResource] = [:]
    private var nextImageIndex = 1
    private let imageSize: AttachmentImageSize

    init(imageSize: AttachmentImageSize) {
      self.imageSize = imageSize
    }

    mutating func addImageAttachment(_ attachment: ChatAttachment) throws {
      guard attachment.kind == .image else { return }
      guard attachmentHrefsByID[attachment.id] == nil else { return }
      guard let dataBase64 = attachment.dataBase64,
        !dataBase64.isEmpty,
        let data = Data(base64Encoded: dataBase64)
      else {
        throw EPUBExportError.unreadableAttachedImage(attachment.displayName)
      }
      guard
        let mediaType = Self.imageMediaType(
          from: data,
          declared: attachment.mimeType,
          suggestedFilename: attachment.filename,
          url: nil)
      else {
        throw EPUBExportError.unsupportedImage(attachment.displayName)
      }

      let prepared = preparedImageData(
        data: data,
        mediaType: mediaType,
        fallbackWidth: attachment.width,
        fallbackHeight: attachment.height)
      let resource = makeResource(
        data: prepared.data,
        mediaType: prepared.mediaType,
        width: prepared.width,
        height: prepared.height,
        suggestedFilename: attachment.filename,
        url: nil)
      resources.append(resource)
      attachmentHrefsByID[attachment.id] = resource.href
      attachmentResourcesByID[attachment.id] = resource
    }

    mutating func addRemoteImage(source: String) async throws {
      let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
      guard remoteHrefsBySource[normalizedSource] == nil else { return }
      guard let url = Self.remoteImageURL(from: normalizedSource) else { return }

      let downloaded: (data: Data, mediaType: String)
      do {
        downloaded = try await Self.downloadRemoteImage(
          from: url,
          displaySource: normalizedSource)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return
      }
      let prepared = preparedImageData(
        data: downloaded.data,
        mediaType: downloaded.mediaType,
        fallbackWidth: nil,
        fallbackHeight: nil)
      let resource = makeResource(
        data: prepared.data,
        mediaType: prepared.mediaType,
        width: prepared.width,
        height: prepared.height,
        suggestedFilename: url.lastPathComponent,
        url: url)
      resources.append(resource)
      remoteHrefsBySource[normalizedSource] = resource.href
      remoteResourcesBySource[normalizedSource] = resource
    }

    mutating func addMermaidDiagram(source: String) async {
      let normalizedSource = MarkdownMermaidRenderer.normalizedSource(source)
      guard !normalizedSource.isEmpty,
        mermaidResourcesBySource[normalizedSource] == nil
      else {
        return
      }

      do {
        guard
          let rendered = try await MarkdownMermaidRenderCache.shared.renderedPNG(
            source: normalizedSource,
            style: .light,
            scale: 2.0)
        else {
          return
        }

        let prepared = preparedImageData(
          data: rendered.data,
          mediaType: "image/png",
          fallbackWidth: rendered.width,
          fallbackHeight: rendered.height)
        let resource = makeResource(
          data: prepared.data,
          mediaType: prepared.mediaType,
          width: prepared.width,
          height: prepared.height,
          suggestedFilename: "mermaid-diagram.png",
          url: nil)
        resources.append(resource)
        mermaidResourcesBySource[normalizedSource] = resource
      } catch {
        return
      }
    }

    func hasImageAttachments(for message: ChatMessage) -> Bool {
      message.attachments.contains { attachment in
        attachment.kind == .image && attachmentHrefsByID[attachment.id] != nil
      }
    }

    func href(for attachment: ChatAttachment) -> String? {
      attachmentHrefsByID[attachment.id]
    }

    func resource(for attachment: ChatAttachment) -> ImageResource? {
      attachmentResourcesByID[attachment.id]
    }

    func href(forMarkdownImageSource source: String) -> String? {
      remoteHrefsBySource[source.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func resource(forMarkdownImageSource source: String) -> ImageResource? {
      remoteResourcesBySource[source.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func resource(forMermaidDiagram source: String) -> ImageResource? {
      mermaidResourcesBySource[MarkdownMermaidRenderer.normalizedSource(source)]
    }

    func firstImageAttachmentDisplayName(in message: ChatMessage) -> String? {
      message.attachments.first { attachment in
        attachment.kind == .image && attachmentHrefsByID[attachment.id] != nil
      }?.displayName
    }

    private mutating func makeResource(
      data: Data,
      mediaType: String,
      width: Int?,
      height: Int?,
      suggestedFilename: String,
      url: URL?
    ) -> ImageResource {
      let resourceIndex = nextImageIndex
      nextImageIndex += 1
      let ext = Self.imageFileExtension(
        mediaType: mediaType,
        suggestedFilename: suggestedFilename,
        url: url)
      let filename = String(format: "image%03d.%@", resourceIndex, ext)
      return ImageResource(
        id: String(format: "img%03d", resourceIndex),
        href: "images/\(filename)",
        mediaType: mediaType,
        data: data,
        width: width,
        height: height)
    }

    private func preparedImageData(
      data: Data,
      mediaType: String,
      fallbackWidth: Int?,
      fallbackHeight: Int?
    ) -> (data: Data, mediaType: String, width: Int?, height: Int?) {
      guard let maxDimension = imageSize.maxDimension else {
        return (data, mediaType, fallbackWidth, fallbackHeight)
      }
      guard let image = UIImage(data: data) else {
        return (data, mediaType, fallbackWidth, fallbackHeight)
      }
      let pixelSize = CGSize(
        width: image.size.width * image.scale,
        height: image.size.height * image.scale)
      let scale =
        max(pixelSize.width, pixelSize.height) > CGFloat(maxDimension)
        ? CGFloat(maxDimension) / max(pixelSize.width, pixelSize.height)
        : 1
      let target = CGSize(
        width: max(1, floor(pixelSize.width * scale)),
        height: max(1, floor(pixelSize.height * scale)))
      let format = UIGraphicsImageRendererFormat.default()
      format.scale = 1
      let renderer = UIGraphicsImageRenderer(size: target, format: format)
      let resized = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: target))
      }
      guard let output = resized.jpegData(compressionQuality: 0.82) else {
        return (
          data,
          mediaType,
          Int(pixelSize.width.rounded()),
          Int(pixelSize.height.rounded())
        )
      }
      return (
        output,
        "image/jpeg",
        Int(target.width.rounded()),
        Int(target.height.rounded())
      )
    }

    private static func remoteImageURL(from source: String) -> URL? {
      MarkdownWebURL.url(from: source)
    }

    private static func downloadRemoteImage(from url: URL, displaySource: String) async throws
      -> (data: Data, mediaType: String)
    {
      var request = URLRequest(url: url)
      request.timeoutInterval = 30
      request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await URLSession.shared.data(for: request)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw EPUBExportError.remoteImageDownloadFailed(displaySource, error.localizedDescription)
      }

      if let http = response as? HTTPURLResponse,
        !(200..<300).contains(http.statusCode)
      {
        throw EPUBExportError.remoteImageDownloadFailed(
          displaySource,
          "HTTP \(http.statusCode)")
      }
      guard data.count <= maxImageBytes else {
        throw EPUBExportError.remoteImageDownloadFailed(displaySource, "image is too large")
      }
      let responseURL = response.url ?? url
      guard
        let mediaType = imageMediaType(
          from: data,
          declared: response.mimeType,
          suggestedFilename: responseURL.lastPathComponent,
          url: responseURL)
      else {
        throw EPUBExportError.unsupportedImage(displaySource)
      }
      return (data, mediaType)
    }

    private static func imageMediaType(
      from data: Data,
      declared: String?,
      suggestedFilename: String,
      url: URL?
    ) -> String? {
      if let mediaType = normalizedImageMediaType(declared) {
        return mediaType
      }
      if dataStarts(data, [0xff, 0xd8, 0xff]) {
        return "image/jpeg"
      }
      if dataStarts(data, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
        return "image/png"
      }
      if dataStarts(data, [0x47, 0x49, 0x46, 0x38]) {
        return "image/gif"
      }
      let header = Array(data.prefix(12))
      if header.count == 12,
        String(bytes: header[0..<4], encoding: .ascii) == "RIFF",
        String(bytes: header[8..<12], encoding: .ascii) == "WEBP"
      {
        return "image/webp"
      }
      if let text = String(data: data.prefix(512), encoding: .utf8),
        text.localizedCaseInsensitiveContains("<svg")
      {
        return "image/svg+xml"
      }
      return normalizedImageMediaType(
        mimeTypeForImageExtension(fileExtension(suggestedFilename: suggestedFilename, url: url)))
    }

    private static func imageFileExtension(
      mediaType: String,
      suggestedFilename: String,
      url: URL?
    ) -> String {
      if let ext = fileExtensionForImageMediaType(mediaType) {
        return ext
      }
      return fileExtension(suggestedFilename: suggestedFilename, url: url) ?? "img"
    }

    private static func fileExtension(suggestedFilename: String, url: URL?) -> String? {
      let filenameExtension = URL(fileURLWithPath: suggestedFilename).pathExtension
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      if isSupportedImageExtension(filenameExtension) {
        return filenameExtension == "jpeg" ? "jpg" : filenameExtension
      }
      let urlExtension =
        url?.pathExtension
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
      if isSupportedImageExtension(urlExtension) {
        return urlExtension == "jpeg" ? "jpg" : urlExtension
      }
      return nil
    }

    private static func normalizedImageMediaType(_ raw: String?) -> String? {
      guard let raw else { return nil }
      let mediaType =
        raw
        .components(separatedBy: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
      guard mediaType.hasPrefix("image/") else { return nil }
      if mediaType == "image/jpg" || mediaType == "image/pjpeg" {
        return "image/jpeg"
      }
      return mediaType
    }

    private static func mimeTypeForImageExtension(_ ext: String?) -> String? {
      switch ext {
      case "jpg", "jpeg": "image/jpeg"
      case "png": "image/png"
      case "gif": "image/gif"
      case "svg": "image/svg+xml"
      case "webp": "image/webp"
      case "heic": "image/heic"
      case "heif": "image/heif"
      case "tif", "tiff": "image/tiff"
      case "bmp": "image/bmp"
      default: nil
      }
    }

    private static func fileExtensionForImageMediaType(_ mediaType: String) -> String? {
      switch normalizedImageMediaType(mediaType) {
      case "image/jpeg": "jpg"
      case "image/png": "png"
      case "image/gif": "gif"
      case "image/svg+xml": "svg"
      case "image/webp": "webp"
      case "image/heic": "heic"
      case "image/heif": "heif"
      case "image/tiff": "tif"
      case "image/bmp": "bmp"
      default: nil
      }
    }

    private static func isSupportedImageExtension(_ ext: String) -> Bool {
      mimeTypeForImageExtension(ext) != nil
    }

    private static func dataStarts(_ data: Data, _ prefix: [UInt8]) -> Bool {
      guard data.count >= prefix.count else { return false }
      return zip(data.prefix(prefix.count), prefix).allSatisfy { $0 == $1 }
    }

    private static let maxImageBytes = 25 * 1024 * 1024
    private static let userAgent = "PocketMai/1.0 (iOS; +https://github.com/trufae/mai)"
  }

  private enum EPUBExportError: LocalizedError {
    case unreadableAttachedImage(String)
    case unsupportedImage(String)
    case remoteImageDownloadFailed(String, String)

    var errorDescription: String? {
      switch self {
      case .unreadableAttachedImage(let name):
        return "Could not read attached image \"\(name)\"."
      case .unsupportedImage(let source):
        return "Could not identify an image format for \"\(source)\"."
      case .remoteImageDownloadFailed(let source, let reason):
        return "Could not download image \"\(source)\": \(reason)."
      }
    }
  }

  struct MessageContent {
    let visibleText: String
    let reasoningSections: [String]

    var hasExportedBody: Bool {
      !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || reasoningSections.contains {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
  }

  private static func buildChapters(
    conversation: Conversation,
    bookTitle: String,
    includeThinking: Bool,
    imageCatalog: ImageResourceCatalog
  ) -> [Chapter] {
    var chapters: [Chapter] = []
    chapters.append(makeTitleChapter(conversation: conversation, bookTitle: bookTitle))

    var exportedMessageCount = 0
    for message in conversation.messages {
      let content = messageContent(for: message, includeThinking: includeThinking)
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

  static func messageContent(for message: ChatMessage, includeThinking: Bool)
    -> MessageContent
  {
    let rendered = MessageContentFilter.render(message.presentationText)
    let reasoningSections =
      includeThinking
      ? rendered.hiddenSections.filter { $0.tag == "think" }.map(\.content)
      : []
    return MessageContent(visibleText: rendered.visibleText, reasoningSections: reasoningSections)
  }

  static func buildImageResourceCatalog(
    conversation: Conversation,
    includeThinking: Bool,
    imageSize: AttachmentImageSize
  ) async throws -> ImageResourceCatalog {
    var catalog = ImageResourceCatalog(imageSize: imageSize)
    for message in conversation.messages {
      for attachment in message.attachments where attachment.kind == .image {
        try catalog.addImageAttachment(attachment)
      }

      let content = messageContent(for: message, includeThinking: includeThinking)
      for source in markdownImageSources(in: content.visibleText) {
        try await catalog.addRemoteImage(source: source)
      }
      await addMermaidDiagrams(in: content.visibleText, to: &catalog)
      for section in content.reasoningSections {
        for source in markdownImageSources(in: section) {
          try await catalog.addRemoteImage(source: source)
        }
        await addMermaidDiagrams(in: section, to: &catalog)
      }
    }
    return catalog
  }

  private static func addMermaidDiagrams(
    in text: String,
    to catalog: inout ImageResourceCatalog
  ) async {
    for block in MarkdownParser.blocks(from: text) {
      if case .mermaid(let source) = block.kind {
        await catalog.addMermaidDiagram(source: source)
      }
    }
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

  struct MarkdownImageToken {
    let altText: String
    let source: String
    let end: Int
  }

  private static func markdownImageSources(in raw: String) -> [String] {
    let chars = Array(MarkdownInlineSymbols.displayString(raw))
    guard chars.contains("!") else { return [] }

    var sources: [String] = []
    var index = 0
    while index < chars.count {
      if let codeSpan = MarkdownInlineCodeSpan.span(in: chars, at: index) {
        index = codeSpan.end
        continue
      }

      if let image = markdownImageToken(in: chars, at: index) {
        sources.append(image.source)
        index = image.end
        continue
      }
      index += 1
    }
    return sources
  }

  static func markdownImageToken(in chars: [Character], at index: Int)
    -> MarkdownImageToken?
  {
    guard index + 1 < chars.count,
      chars[index] == "!",
      chars[index + 1] == "[",
      !isEscaped(chars, at: index),
      let altEnd = findImageAltEnd(in: chars, start: index + 2),
      altEnd + 1 < chars.count,
      chars[altEnd + 1] == "(",
      let destinationEnd = findImageDestinationEnd(in: chars, start: altEnd + 2)
    else {
      return nil
    }

    let alt = String(chars[(index + 2)..<altEnd])
    let destination = String(chars[(altEnd + 2)..<destinationEnd])
    guard let source = markdownImageSource(from: destination) else { return nil }
    return MarkdownImageToken(altText: alt, source: source, end: destinationEnd + 1)
  }

  private static func markdownImageSource(from destination: String) -> String? {
    let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.first == "<", let close = trimmed.firstIndex(of: ">") {
      let start = trimmed.index(after: trimmed.startIndex)
      guard start <= close else { return nil }
      return String(trimmed[start..<close])
    }

    let chars = Array(trimmed)
    var end = 0
    while end < chars.count, !chars[end].isWhitespace {
      end += 1
    }
    guard end > 0 else { return nil }
    return String(chars[0..<end])
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  private static func findImageAltEnd(in chars: [Character], start: Int) -> Int? {
    var index = start
    while index < chars.count {
      if chars[index] == "\\" {
        index += 2
        continue
      }
      if chars[index] == "]" {
        return index
      }
      if chars[index] == "\n" || chars[index] == "\r" {
        return nil
      }
      index += 1
    }
    return nil
  }

  private static func findImageDestinationEnd(in chars: [Character], start: Int) -> Int? {
    var depth = 0
    var index = start
    while index < chars.count {
      if chars[index] == "\\" {
        index += 2
        continue
      }
      if chars[index] == "\n" || chars[index] == "\r" {
        return nil
      }
      if chars[index] == "(" {
        depth += 1
      } else if chars[index] == ")" {
        if depth == 0 {
          return index
        }
        depth -= 1
      }
      index += 1
    }
    return nil
  }

  private static func isEscaped(_ chars: [Character], at index: Int) -> Bool {
    guard index > 0 else { return false }
    var slashCount = 0
    var cursor = index - 1
    while cursor >= 0, chars[cursor] == "\\" {
      slashCount += 1
      cursor -= 1
    }
    return slashCount % 2 == 1
  }

  private static func inlineHTML(_ raw: String, imageCatalog: ImageResourceCatalog) -> String {
    let chars = Array(MarkdownInlineSymbols.displayString(raw))
    var result = ""
    var index = 0
    while index < chars.count {
      let c = chars[index]

      if c == "\\", index + 1 < chars.count {
        let next = chars[index + 1]
        if "\\`*_{}[]()#+-.!~".contains(next) {
          result += xmlEscaped(String(next))
          index += 2
          continue
        }
      }

      if let codeSpan = MarkdownInlineCodeSpan.span(in: chars, at: index) {
        result += inlineCodeHTML(codeSpan.code)
        index = codeSpan.end
        continue
      }

      if c == "~", index + 1 < chars.count, chars[index + 1] == "~" {
        if let end = findClose(chars: chars, start: index + 2, marker: "~~") {
          let inner = String(chars[(index + 2)..<end])
          if !inner.isEmpty {
            result += "<del>\(inlineHTML(inner, imageCatalog: imageCatalog))</del>"
            index = end + 2
            continue
          }
        }
      }

      if (c == "*" || c == "_") && index + 1 < chars.count && chars[index + 1] == c {
        let marker = String([c, c])
        if let end = findClose(chars: chars, start: index + 2, marker: marker) {
          let inner = String(chars[(index + 2)..<end])
          result += "<strong>\(inlineHTML(inner, imageCatalog: imageCatalog))</strong>"
          index = end + marker.count
          continue
        }
      }

      if c == "*" || c == "_" {
        if let end = findClose(chars: chars, start: index + 1, marker: String(c)) {
          let inner = String(chars[(index + 1)..<end])
          if !inner.isEmpty {
            result += "<em>\(inlineHTML(inner, imageCatalog: imageCatalog))</em>"
            index = end + 1
            continue
          }
        }
      }

      if let image = markdownImageToken(in: chars, at: index) {
        if let src = imageCatalog.href(forMarkdownImageSource: image.source) {
          result += "<img src=\"\(xmlEscaped(src))\" alt=\"\(xmlEscaped(image.altText))\"/>"
        } else if let href = MarkdownWebURL.normalizedString(from: image.source) {
          let label =
            image.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? image.source
            : image.altText
          result +=
            "<a href=\"\(xmlEscaped(href))\">\(inlineHTML(label, imageCatalog: imageCatalog))</a>"
        } else {
          result += xmlEscaped("![\(image.altText)](\(image.source))")
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
          result +=
            "<a href=\"\(xmlEscaped(url))\">\(inlineHTML(label, imageCatalog: imageCatalog))</a>"
          index = urlEnd + 1
          continue
        }
      }

      if c == "\n" {
        result += "<br/>"
        index += 1
        continue
      }

      result += xmlEscaped(String(c))
      index += 1
    }
    return result
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
    let raw = MarkdownInlineSymbols.displayString(raw)
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
      if c == "~", index + 1 < chars.count, chars[index + 1] == "~" {
        if let end = findClose(chars: chars, start: index + 2, marker: "~~") {
          result += stripInlineMarkdown(String(chars[(index + 2)..<end]))
          index = end + 2
          continue
        }
      }
      if let image = markdownImageToken(in: chars, at: index) {
        result += stripInlineMarkdown(image.altText)
        index = image.end
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

struct StoredZipArchive {
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
