import Foundation

/// The identity and timestamps every stored chat shape shares, whatever else a
/// host keeps in it. PocketMai's conversations and summaries and MaiCore's
/// `AgentChat` all conform, so ordering and newest-wins merging exist once.
public protocol ChatRecord: Identifiable where ID == UUID {
  var createdAt: Date { get }
  var updatedAt: Date { get }
}

extension ChatRecord {
  /// Newest first: last update, then creation. The order sidebars list chats in.
  public static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    return lhs.createdAt > rhs.createdAt
  }

  /// Keeps one record per id, preferring the most recently updated copy, as
  /// when the same chat exists both on a device and in iCloud. The order of
  /// first appearance is kept.
  public static func newest(of records: [Self]) -> [Self] {
    var order: [UUID] = []
    var byID: [UUID: Self] = [:]
    for record in records {
      guard let existing = byID[record.id] else {
        order.append(record.id)
        byID[record.id] = record
        continue
      }
      if existing.updatedAt < record.updatedAt
        || (existing.updatedAt == record.updatedAt && existing.createdAt < record.createdAt)
      {
        byID[record.id] = record
      }
    }
    return order.compactMap { byID[$0] }
  }
}

/// A chat a `ChatFileStore` can keep: codable, and able to say whether it is an
/// untouched placeholder that should never reach disk.
public protocol StoredChat: ChatRecord, Codable, Sendable {
  var isDisposable: Bool { get }
}

/// How JSON files are written and read. The default writes ISO 8601 dates as
/// PocketMai always has, keeping fractional seconds so ordering survives a
/// reload, and still reads the numeric dates earlier MaiCore files used, so
/// no existing file becomes unreadable.
public struct MaiJSONCoding: Sendable {
  public var makeEncoder: @Sendable () -> JSONEncoder
  public var makeDecoder: @Sendable () -> JSONDecoder

  public init(
    makeEncoder: @escaping @Sendable () -> JSONEncoder,
    makeDecoder: @escaping @Sendable () -> JSONDecoder
  ) {
    self.makeEncoder = makeEncoder
    self.makeDecoder = makeDecoder
  }

  public static let `default` = MaiJSONCoding(
    makeEncoder: {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .custom(MaiJSONCoding.encodeFractionalISODate)
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return encoder
    },
    makeDecoder: {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .custom(MaiJSONCoding.decodeFlexibleDate)
      return decoder
    })

  /// ISO 8601 with millisecond precision, such as `2026-09-06T11:40:00.123Z`.
  public static func encodeFractionalISODate(_ date: Date, to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
  }

  /// Accepts ISO 8601 text, with or without fractional seconds, and the
  /// seconds-since-reference-date numbers Foundation encodes by default.
  public static func decodeFlexibleDate(from decoder: Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    if let seconds = try? container.decode(Double.self) {
      return Date(timeIntervalSinceReferenceDate: seconds)
    }
    let text = try container.decode(String.self)
    if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
      return date
    }
    throw DecodingError.dataCorruptedError(
      in: container, debugDescription: "Unrecognized date \"\(text)\".")
  }
}

public enum ChatFileStoreError: LocalizedError, Sendable {
  /// The file exists but could not be read.
  case unreadable(URL, any Error)
  /// The file was read but does not decode as a chat.
  case undecodable(URL, any Error)
  /// A restore would overwrite a live chat file.
  case alreadyExists(URL)

  public var url: URL {
    switch self {
    case .unreadable(let url, _), .undecodable(let url, _), .alreadyExists(let url): url
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unreadable(let url, let error):
      "Could not read chat file \(url.lastPathComponent): \(error.localizedDescription)"
    case .undecodable(let url, let error):
      "Could not decode chat file \(url.lastPathComponent): \(error.localizedDescription)"
    case .alreadyExists(let url):
      "A chat file named \(url.lastPathComponent) already exists."
    }
  }
}

/// Persists chats as one JSON file per chat inside a directory, the layout
/// PocketMai has used since its first release, so hosts can list chats cheaply
/// and load a transcript only when it is opened.
///
/// The shared rules live here. A disposable chat, an untouched placeholder, is
/// never written, so an empty chat left behind on any platform leaves no file.
/// Saving never deletes: a file that already exists stays until a host removes
/// it on purpose, so upgrading a store cannot lose a chat. Files that fail to
/// decode are reported, and can be quarantined beside the live chats under a
/// `.json.corrupt` name and restored later, but are never discarded.
public struct ChatFileStore<Chat: StoredChat>: Sendable {
  public static var fileExtension: String { "json" }
  public static var quarantineExtension: String { "corrupt" }

  public let directoryURL: URL
  public let coding: MaiJSONCoding

  public init(directoryURL: URL, coding: MaiJSONCoding = .default) {
    self.directoryURL = directoryURL
    self.coding = coding
  }

  public func fileURL(for id: UUID) -> URL {
    directoryURL.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
  }

  public func fileExists(for id: UUID) -> Bool {
    FileManager.default.fileExists(atPath: fileURL(for: id).path)
  }

  /// IDs of every chat file present, whatever their contents. Other JSON
  /// files in the directory, such as a host's index, are not chats.
  public func chatIDs() throws -> [UUID] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == Self.fileExtension }
    .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    .sorted { $0.uuidString < $1.uuidString }
  }

  /// The chat with an id, or nil when it has no file.
  public func loadChat(id: UUID) throws -> Chat? {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try decodeChat(at: url)
  }

  /// Every readable, non-disposable chat. Failures go to `onFailure` and the
  /// files stay in place.
  public func loadChats(onFailure: ((ChatFileStoreError) -> Void)? = nil) throws -> [Chat] {
    try loadRecords(Chat.self, onFailure: onFailure).filter { !$0.isDisposable }
  }

  /// Decodes every chat file as another shape, typically a summary that skips
  /// the transcript.
  public func loadRecords<Record: Decodable>(
    _ type: Record.Type,
    onFailure: ((ChatFileStoreError) -> Void)? = nil
  ) throws -> [Record] {
    var records: [Record] = []
    for id in try chatIDs() {
      do {
        records.append(try decode(Record.self, at: fileURL(for: id)))
      } catch let error as ChatFileStoreError {
        onFailure?(error)
      }
    }
    return records
  }

  /// Writes the chat unless it is disposable. Answers whether it was written.
  /// An existing file is left alone either way; use `delete` to remove one.
  @discardableResult
  public func save(_ chat: Chat, evenIfDisposable: Bool = false) throws -> Bool {
    guard evenIfDisposable || !chat.isDisposable else { return false }
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try coding.makeEncoder().encode(chat).write(to: fileURL(for: chat.id), options: .atomic)
    return true
  }

  @discardableResult
  public func delete(id: UUID) throws -> Bool {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    try FileManager.default.removeItem(at: url)
    return true
  }

  public func decodeChat(from data: Data) throws -> Chat {
    try coding.makeDecoder().decode(Chat.self, from: data)
  }

  public func decodeChat(at url: URL) throws -> Chat {
    try decode(Chat.self, at: url)
  }

  /// Moves a file that does not decode out of the way, keeping its bytes, so
  /// the rest of the store keeps loading and people can recover it later.
  /// Answers where it went, or nil when it was missing or could not be moved.
  @discardableResult
  public func quarantine(fileAt source: URL) -> URL? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: source.path) else { return nil }
    let directory = source.deletingLastPathComponent()
    let stem = source.deletingPathExtension().lastPathComponent
    var destination = source.appendingPathExtension(Self.quarantineExtension)
    var suffix = 2
    while fileManager.fileExists(atPath: destination.path) {
      destination = directory.appendingPathComponent(
        "\(stem)-\(suffix).\(Self.fileExtension).\(Self.quarantineExtension)")
      suffix += 1
    }
    do {
      try fileManager.moveItem(at: source, to: destination)
      return destination
    } catch {
      return nil
    }
  }

  /// Quarantined chat files in this directory, by name.
  public func quarantinedFileURLs() -> [URL] {
    Self.quarantinedFileURLs(in: directoryURL)
  }

  public static func quarantinedFileURLs(in directory: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
      .filter {
        $0.pathExtension == quarantineExtension
          && $0.deletingPathExtension().pathExtension == fileExtension
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Puts a quarantined file back among the live chats once it decodes again,
  /// for example after a decoder fix. The file is moved, not copied, and never
  /// overwrites a live chat.
  public func restoreQuarantinedFile(at source: URL) throws -> Chat {
    let chat = try decodeChat(at: source)
    let destination = fileURL(for: chat.id)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw ChatFileStoreError.alreadyExists(destination)
    }
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: source, to: destination)
    return chat
  }

  private func decode<Record: Decodable>(_ type: Record.Type, at url: URL) throws -> Record {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw ChatFileStoreError.unreadable(url, error)
    }
    do {
      return try coding.makeDecoder().decode(Record.self, from: data)
    } catch {
      throw ChatFileStoreError.undecodable(url, error)
    }
  }
}
