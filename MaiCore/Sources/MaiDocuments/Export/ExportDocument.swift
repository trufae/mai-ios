import Foundation
import MaiMarkdown

/// What every export format is written from: a conversation reduced to who
/// said what, in markdown, with the images that go with it. Hosts build one
/// from their own chat model and never see the formats' internals.
public struct ExportDocument: Equatable, Sendable {
  public var identifier: UUID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  /// The program writing the file, as it appears in document metadata.
  public var generator: String
  public var entries: [ExportEntry]
  /// Images the host fetched for `![alt](source)` references, keyed by the
  /// source exactly as written. Unresolved sources are exported as links.
  public var inlineImages: [String: ExportImage]
  /// Rendered diagrams for ```mermaid fences, keyed by the trimmed source.
  /// A fence without one is exported as code.
  public var diagrams: [String: ExportImage]

  public init(
    identifier: UUID = UUID(),
    title: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    generator: String = "MaiCore",
    entries: [ExportEntry] = [],
    inlineImages: [String: ExportImage] = [:],
    diagrams: [String: ExportImage] = [:]
  ) {
    self.identifier = identifier
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.generator = generator
    self.entries = entries
    self.inlineImages = inlineImages
    self.diagrams = diagrams
  }

  /// Entries that have something to show; the rest are skipped by every format.
  public var exportedEntries: [ExportEntry] {
    entries.filter { !$0.isEmpty }
  }

  /// The source of every ```mermaid fence in a markdown text, for a host that
  /// renders diagrams to fill `diagrams` with.
  public static func mermaidSources(in text: String) -> [String] {
    MarkdownBlockParser.blocks(from: text).compactMap { block in
      guard case .code(let language, let code) = block, language.lowercased() == "mermaid"
      else { return nil }
      return code
    }
  }

  public var summary: ExportSummary {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    let count = entries.count
    return ExportSummary(
      title: trimmed.isEmpty ? "Chat" : trimmed,
      started: formatter.string(from: createdAt),
      lastUpdated: formatter.string(from: updatedAt),
      messageCount: "\(count) message\(count == 1 ? "" : "s")")
  }
}

/// The lines every format puts on its title page.
public struct ExportSummary: Equatable, Sendable {
  public var title: String
  public var started: String
  public var lastUpdated: String
  public var messageCount: String
}

public enum ExportRole: String, Codable, CaseIterable, Sendable {
  case user
  case assistant
  case system
  case tool
  case error

  public var displayName: String {
    switch self {
    case .user: "You"
    case .assistant: "Assistant"
    case .system: "System"
    case .tool: "Tool"
    case .error: "Error"
    }
  }
}

public struct ExportEntry: Equatable, Sendable {
  public var role: ExportRole
  /// Hidden reasoning, one markdown text per section, shown before the body.
  public var reasoning: [String]
  /// The visible markdown.
  public var body: String
  /// Images attached to the message, shown after the body.
  public var attachments: [ExportImage]

  public init(
    role: ExportRole,
    reasoning: [String] = [],
    body: String,
    attachments: [ExportImage] = []
  ) {
    self.role = role
    self.reasoning = reasoning
    self.body = body
    self.attachments = attachments
  }

  public var isEmpty: Bool {
    body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && reasoning.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      && attachments.isEmpty
  }
}

public struct ExportImage: Equatable, Sendable {
  public var name: String
  public var mediaType: String
  public var data: Data
  public var width: Int?
  public var height: Int?

  public init(name: String, mediaType: String, data: Data, width: Int? = nil, height: Int? = nil) {
    self.name = name
    self.mediaType = mediaType
    self.data = data
    self.width = width
    self.height = height
  }
}

// MARK: - Shared by the packaged formats

/// One image file inside an EPUB or DOCX package.
struct ExportResource {
  var id: String
  var href: String
  var mediaType: String
  var data: Data
  var width: Int?
  var height: Int?
}

/// Assigns package paths to every image of a document once, so EPUB and DOCX
/// name and look them up the same way.
struct ExportImageCatalog {
  private(set) var resources: [ExportResource] = []
  private var attachments: [String: ExportResource] = [:]
  private var inline: [String: ExportResource] = [:]
  private var diagrams: [String: ExportResource] = [:]

  init(document: ExportDocument) {
    for (entryIndex, entry) in document.exportedEntries.enumerated() {
      for (attachmentIndex, image) in entry.attachments.enumerated() {
        attachments["\(entryIndex):\(attachmentIndex)"] = add(image)
      }
    }
    for source in document.inlineImages.keys.sorted() {
      inline[Self.key(source)] = add(document.inlineImages[source]!)
    }
    for source in document.diagrams.keys.sorted() {
      diagrams[Self.key(source)] = add(document.diagrams[source]!)
    }
  }

  func attachment(entry: Int, index: Int) -> ExportResource? {
    attachments["\(entry):\(index)"]
  }

  func inlineImage(source: String) -> ExportResource? {
    inline[Self.key(source)]
  }

  func diagram(source: String) -> ExportResource? {
    diagrams[Self.key(source)]
  }

  private static func key(_ source: String) -> String {
    source.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private mutating func add(_ image: ExportImage) -> ExportResource {
    let index = resources.count + 1
    let resource = ExportResource(
      id: String(format: "img%03d", index),
      href: String(format: "images/image%03d.%@", index, Self.fileExtension(for: image.mediaType)),
      mediaType: image.mediaType,
      data: image.data,
      width: image.width,
      height: image.height)
    resources.append(resource)
    return resource
  }

  static func fileExtension(for mediaType: String) -> String {
    switch mediaType.lowercased() {
    case "image/jpeg", "image/jpg": "jpg"
    case "image/png": "png"
    case "image/gif": "gif"
    case "image/svg+xml": "svg"
    case "image/webp": "webp"
    case "image/heic": "heic"
    case "image/tiff": "tif"
    case "image/bmp": "bmp"
    default: "img"
    }
  }
}

enum ExportXML {
  static func escaped(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.count)
    for character in value {
      switch character {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "'": result += "&#39;"
      default: result.append(character)
      }
    }
    return result
  }

  static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  /// A web address a reader can follow, or nil for anything else.
  static func webURL(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
      ["http", "https", "mailto"].contains(scheme)
    else { return nil }
    return url.absoluteString
  }
}
