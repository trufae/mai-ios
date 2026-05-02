import Foundation

struct PersistedConversations: Codable {
  var conversations: [Conversation]
}

private struct PersistedConversationIndex: Codable {
  var version = 2
  var ids: [UUID]
  var summaries: [ConversationSummary]?
}

final class PersistenceStore: @unchecked Sendable {
  private let fileManager: FileManager
  private let baseURL: URL
  private let writeQueue = DispatchQueue(
    label: "dev.mai.chat.persistence", qos: .userInitiated)
  private let debounce: TimeInterval = 0.4
  // Touched only from writeQueue; serial access guarantees thread-safety.
  private var pendingSettings: DispatchWorkItem?
  private var pendingConversations: DispatchWorkItem?
  private var persistedConversationsByID: [UUID: Conversation] = [:]

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let documents =
      fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    baseURL = documents.appendingPathComponent("PocketMai", isDirectory: true)
  }

  private var conversationsURL: URL {
    baseURL.appendingPathComponent("conversations.json")
  }

  private var conversationsDirectoryURL: URL {
    baseURL.appendingPathComponent("conversations", isDirectory: true)
  }

  private var conversationsIndexURL: URL {
    conversationsDirectoryURL.appendingPathComponent("index.json")
  }

  private var settingsURL: URL {
    baseURL.appendingPathComponent("settings.json")
  }

  func loadConversations() -> [Conversation] {
    if let conversations = loadIndexedConversations() {
      seedPersistedSnapshot(conversations)
      return conversations
    }

    let conversations = loadLegacyConversations()
    if !conversations.isEmpty {
      saveConversations(conversations)
    }
    return conversations
  }

  func loadConversationSummaries() -> [ConversationSummary] {
    guard let data = try? Data(contentsOf: conversationsIndexURL),
      let index = try? makeDecoder().decode(PersistedConversationIndex.self, from: data)
    else {
      return []
    }
    if let summaries = index.summaries {
      let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
      return index.ids.compactMap { byID[$0] }
    }
    return []
  }

  func loadConversation(id: UUID) -> Conversation? {
    let url = conversationFileURL(for: id)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? makeDecoder().decode(Conversation.self, from: data)
  }

  private func loadIndexedConversations() -> [Conversation]? {
    guard let data = try? Data(contentsOf: conversationsIndexURL),
      let index = try? makeDecoder().decode(PersistedConversationIndex.self, from: data)
    else {
      return nil
    }

    let decoder = makeDecoder()
    return index.ids.compactMap { id in
      let url = conversationFileURL(for: id)
      guard let data = try? Data(contentsOf: url) else { return nil }
      return try? decoder.decode(Conversation.self, from: data)
    }
  }

  private func loadLegacyConversations() -> [Conversation] {
    guard let data = try? Data(contentsOf: conversationsURL) else { return [] }
    let decoder = makeDecoder()
    if let envelope = try? decoder.decode(PersistedConversations.self, from: data) {
      return envelope.conversations
    }
    return (try? decoder.decode([Conversation].self, from: data)) ?? []
  }

  func saveConversations(_ conversations: [Conversation]) {
    let ids = conversations.map(\.id)
    let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    let conversationsDir = conversationsDirectoryURL
    let indexURL = conversationsIndexURL
    let legacyURL = conversationsURL
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.pendingConversations?.cancel()
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let changed = conversations.filter { self.persistedConversationsByID[$0.id] != $0 }
        let persisted = Self.persistConversations(
          changed,
          ids: ids,
          summaries: conversations.map(ConversationSummary.init),
          conversationsDir: conversationsDir,
          indexURL: indexURL,
          legacyURL: legacyURL,
          writeIndex: true
        )
        if persisted {
          self.persistedConversationsByID = byID
        }
      }
      self.pendingConversations = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func loadSettings() -> AppSettings {
    guard let data = try? Data(contentsOf: settingsURL),
      let settings = try? makeDecoder().decode(AppSettings.self, from: data)
    else {
      return .defaults
    }
    return settings
  }

  func saveSettings(_ settings: AppSettings) {
    let snapshot = settings
    let url = settingsURL
    let dir = baseURL
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.pendingSettings?.cancel()
      let item = DispatchWorkItem { Self.persist(snapshot, to: url, dir: dir) }
      self.pendingSettings = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func factoryReset() {
    let baseURL = baseURL
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.pendingSettings?.cancel()
      self.pendingSettings = nil
      self.pendingConversations?.cancel()
      self.pendingConversations = nil
      self.persistedConversationsByID.removeAll()
      try? self.fileManager.removeItem(at: baseURL)
    }
  }

  private static func persist<T: Encodable>(_ value: T, to url: URL, dir: URL) {
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(value)
      try data.write(to: url, options: [.atomic])
    } catch {
      // Persistence errors are surfaced through the next successful read; avoid blocking.
    }
  }

  private static func persistConversations(
    _ conversations: [Conversation],
    ids: [UUID],
    summaries: [ConversationSummary],
    conversationsDir: URL,
    indexURL: URL,
    legacyURL: URL,
    writeIndex: Bool
  ) -> Bool {
    do {
      let fileManager = FileManager.default
      try fileManager.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
      let encoder = makeEncoder()
      for conversation in conversations {
        let url = conversationFileURL(for: conversation.id, in: conversationsDir)
        let data = try encoder.encode(conversation)
        try data.write(to: url, options: [.atomic])
      }

      let liveFilenames = Set(ids.map { conversationFilename(for: $0) })
      let files =
        (try? fileManager.contentsOfDirectory(
          at: conversationsDir, includingPropertiesForKeys: nil
        )) ?? []
      for file in files
      where file.lastPathComponent != indexURL.lastPathComponent
        && file.pathExtension == "json"
        && !liveFilenames.contains(file.lastPathComponent)
      {
        try? fileManager.removeItem(at: file)
      }

      if writeIndex {
        let index = PersistedConversationIndex(ids: ids, summaries: summaries)
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: [.atomic])
      }
      try? fileManager.removeItem(at: legacyURL)
      return true
    } catch {
      return false
    }
  }

  private func seedPersistedSnapshot(_ conversations: [Conversation]) {
    let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    writeQueue.async { [weak self] in
      self?.persistedConversationsByID = byID
    }
  }

  private func conversationFileURL(for id: UUID) -> URL {
    Self.conversationFileURL(for: id, in: conversationsDirectoryURL)
  }

  private static func conversationFileURL(for id: UUID, in directory: URL) -> URL {
    directory.appendingPathComponent(conversationFilename(for: id))
  }

  private static func conversationFilename(for id: UUID) -> String {
    "\(id.uuidString).json"
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
