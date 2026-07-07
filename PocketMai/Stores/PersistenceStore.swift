import Foundation

struct PersistedConversations: Codable {
  var conversations: [Conversation]
}

private struct PersistedConversationIndex: Codable {
  var version = 2
  var ids: [UUID]
  var summaries: [ConversationSummary]?
}

private struct PersistedDrafts: Codable {
  var version = 1
  var drafts: [String: String]
}

private struct ConversationStorageURLs {
  var baseURL: URL

  var conversationsURL: URL {
    baseURL.appendingPathComponent("conversations.json")
  }

  var conversationsDirectoryURL: URL {
    baseURL.appendingPathComponent("conversations", isDirectory: true)
  }

  var conversationsIndexURL: URL {
    conversationsDirectoryURL.appendingPathComponent("index.json")
  }
}

final class PersistenceStore: @unchecked Sendable {
  private let fileManager: FileManager
  private let localBaseURL: URL
  private let iCloudFallbackBaseURL: URL
  private let writeQueue = DispatchQueue(
    label: "dev.mai.chat.persistence", qos: .userInitiated)
  private let debounce: TimeInterval = 0.4
  // Touched only from writeQueue; serial access guarantees thread-safety.
  private var pendingSettings: DispatchWorkItem?
  private var pendingConversations: DispatchWorkItem?
  private var pendingDrafts: DispatchWorkItem?
  private var persistedConversationsByID: [UUID: Conversation] = [:]

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    PocketMaiDirectories.prepareLaunchStorage(fileManager: fileManager)
    localBaseURL = PocketMaiDirectories.appDataURL
    iCloudFallbackBaseURL = PocketMaiDirectories.appDataURL
      .appendingPathComponent("iCloud-conversations", isDirectory: true)
    try? fileManager.createDirectory(at: localBaseURL, withIntermediateDirectories: true)
  }

  private var localStorageURLs: ConversationStorageURLs {
    ConversationStorageURLs(baseURL: localBaseURL)
  }

  private func iCloudStorageURLs() -> ConversationStorageURLs {
    if let baseURL = resolvedICloudBaseURL() {
      migrateFallbackICloudConversationsIfNeeded(to: baseURL)
      return ConversationStorageURLs(baseURL: baseURL)
    }
    return ConversationStorageURLs(baseURL: iCloudFallbackBaseURL)
  }

  private func resolvedICloudBaseURL() -> URL? {
    fileManager.url(forUbiquityContainerIdentifier: nil)?
      .appendingPathComponent("Documents", isDirectory: true)
      .appendingPathComponent("PocketMai", isDirectory: true)
      .appendingPathComponent("SharedConversations", isDirectory: true)
  }

  private var settingsURL: URL {
    localBaseURL.appendingPathComponent("settings.json")
  }

  private var draftsURL: URL {
    localBaseURL.appendingPathComponent("drafts.json")
  }

  func loadConversations() -> [Conversation] {
    var conversations = loadConversations(from: localStorageURLs)
    conversations.append(contentsOf: loadConversations(from: iCloudStorageURLs()))
    conversations = Self.mergedConversations(conversations)
    seedPersistedSnapshot(conversations)
    return conversations
  }

  func loadConversationSummaries() -> [ConversationSummary] {
    Self.mergedSummaries(
      loadConversationSummaries(from: localStorageURLs)
        + loadConversationSummaries(from: iCloudStorageURLs()))
  }

  func loadConversation(id: UUID) -> Conversation? {
    let candidates = [
      loadConversation(id: id, from: localStorageURLs),
      loadConversation(id: id, from: iCloudStorageURLs()),
    ].compactMap { $0 }
    return candidates.max { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt < rhs.updatedAt
      }
      return lhs.createdAt < rhs.createdAt
    }
  }

  private func loadConversations(from storage: ConversationStorageURLs) -> [Conversation] {
    if let conversations = loadIndexedConversations(from: storage) {
      return conversations
    }

    let conversations = loadLegacyConversations(from: storage)
    if !conversations.isEmpty {
      _ = Self.persistConversations(
        conversations,
        ids: conversations.map(\.id),
        summaries: conversations.map(ConversationSummary.init),
        storage: storage,
        writeIndex: true)
    }
    return conversations
  }

  private func loadConversationSummaries(from storage: ConversationStorageURLs)
    -> [ConversationSummary]
  {
    guard let data = try? Data(contentsOf: storage.conversationsIndexURL),
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

  private func loadConversation(id: UUID, from storage: ConversationStorageURLs) -> Conversation? {
    let url = Self.conversationFileURL(for: id, in: storage.conversationsDirectoryURL)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? makeDecoder().decode(Conversation.self, from: data)
  }

  private func loadIndexedConversations(from storage: ConversationStorageURLs) -> [Conversation]? {
    guard let data = try? Data(contentsOf: storage.conversationsIndexURL),
      let index = try? makeDecoder().decode(PersistedConversationIndex.self, from: data)
    else {
      return nil
    }

    let decoder = makeDecoder()
    return index.ids.compactMap { id in
      let url = Self.conversationFileURL(for: id, in: storage.conversationsDirectoryURL)
      guard let data = try? Data(contentsOf: url) else { return nil }
      return try? decoder.decode(Conversation.self, from: data)
    }
  }

  private func loadLegacyConversations(from storage: ConversationStorageURLs) -> [Conversation] {
    guard let data = try? Data(contentsOf: storage.conversationsURL) else { return [] }
    let decoder = makeDecoder()
    if let envelope = try? decoder.decode(PersistedConversations.self, from: data) {
      return envelope.conversations
    }
    return (try? decoder.decode([Conversation].self, from: data)) ?? []
  }

  func saveConversations(_ conversations: [Conversation]) {
    let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    let localStorage = localStorageURLs
    let iCloudStorage = iCloudStorageURLs()
    let localConversations = conversations.filter { $0.folderID != ConversationFolder.iCloudID }
    let iCloudConversations = conversations.filter { $0.folderID == ConversationFolder.iCloudID }
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.pendingConversations?.cancel()
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let localChanged = localConversations.filter {
          self.persistedConversationsByID[$0.id] != $0
        }
        let iCloudChanged = iCloudConversations.filter {
          self.persistedConversationsByID[$0.id] != $0
        }
        let persistedLocal = Self.persistConversations(
          localChanged,
          ids: localConversations.map(\.id),
          summaries: localConversations.map(ConversationSummary.init),
          storage: localStorage,
          writeIndex: true
        )
        let persistedICloud = Self.persistConversations(
          iCloudChanged,
          ids: iCloudConversations.map(\.id),
          summaries: iCloudConversations.map(ConversationSummary.init),
          storage: iCloudStorage,
          writeIndex: true
        )
        if persistedLocal && persistedICloud {
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
    let dir = localBaseURL
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.pendingSettings?.cancel()
      let item = DispatchWorkItem { Self.persist(snapshot, to: url, dir: dir) }
      self.pendingSettings = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func loadDrafts() -> [UUID: String] {
    guard let data = try? Data(contentsOf: draftsURL),
      let persisted = try? makeDecoder().decode(PersistedDrafts.self, from: data)
    else {
      return [:]
    }
    var drafts: [UUID: String] = [:]
    for (key, text) in persisted.drafts {
      guard let id = UUID(uuidString: key), !text.isEmpty else { continue }
      drafts[id] = text
    }
    return drafts
  }

  func saveDrafts(_ drafts: [UUID: String]) {
    let snapshot = PersistedDrafts(
      drafts: Dictionary(uniqueKeysWithValues: drafts.map { ($0.key.uuidString, $0.value) }))
    let url = draftsURL
    let dir = localBaseURL
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.pendingDrafts?.cancel()
      let item = DispatchWorkItem { Self.persist(snapshot, to: url, dir: dir) }
      self.pendingDrafts = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func factoryReset() {
    let localBaseURL = localBaseURL
    let iCloudBaseURL = iCloudStorageURLs().baseURL
    let iCloudFallbackBaseURL = iCloudFallbackBaseURL
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.pendingSettings?.cancel()
      self.pendingSettings = nil
      self.pendingConversations?.cancel()
      self.pendingConversations = nil
      self.pendingDrafts?.cancel()
      self.pendingDrafts = nil
      self.persistedConversationsByID.removeAll()
      try? self.fileManager.removeItem(at: localBaseURL)
      if iCloudBaseURL != localBaseURL {
        try? self.fileManager.removeItem(at: iCloudBaseURL)
      }
      if iCloudFallbackBaseURL != localBaseURL {
        try? self.fileManager.removeItem(at: iCloudFallbackBaseURL)
      }
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
    storage: ConversationStorageURLs,
    writeIndex: Bool
  ) -> Bool {
    do {
      let fileManager = FileManager.default
      let conversationsDir = storage.conversationsDirectoryURL
      let indexURL = storage.conversationsIndexURL
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
      try? fileManager.removeItem(at: storage.conversationsURL)
      return true
    } catch {
      return false
    }
  }

  private func migrateFallbackICloudConversationsIfNeeded(to cloudBaseURL: URL) {
    let fallbackStorage = ConversationStorageURLs(baseURL: iCloudFallbackBaseURL)
    guard fallbackStorage.baseURL != cloudBaseURL else { return }
    let fallbackConversations = loadConversations(from: fallbackStorage)
    guard !fallbackConversations.isEmpty else { return }

    let cloudStorage = ConversationStorageURLs(baseURL: cloudBaseURL)
    let merged = Self.mergedConversations(
      loadConversations(from: cloudStorage) + fallbackConversations)
    let persisted = Self.persistConversations(
      merged,
      ids: merged.map(\.id),
      summaries: merged.map(ConversationSummary.init),
      storage: cloudStorage,
      writeIndex: true)
    if persisted {
      try? fileManager.removeItem(at: fallbackStorage.baseURL)
    }
  }

  private func seedPersistedSnapshot(_ conversations: [Conversation]) {
    let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    writeQueue.async { [weak self] in
      self?.persistedConversationsByID = byID
    }
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

  private static func mergedConversations(_ conversations: [Conversation]) -> [Conversation] {
    var byID: [UUID: Conversation] = [:]
    for conversation in conversations {
      guard let existing = byID[conversation.id] else {
        byID[conversation.id] = conversation
        continue
      }
      if existing.updatedAt < conversation.updatedAt
        || (existing.updatedAt == conversation.updatedAt && existing.createdAt < conversation.createdAt)
      {
        byID[conversation.id] = conversation
      }
    }
    return Array(byID.values)
  }

  private static func mergedSummaries(_ summaries: [ConversationSummary]) -> [ConversationSummary] {
    var byID: [UUID: ConversationSummary] = [:]
    for summary in summaries {
      guard let existing = byID[summary.id] else {
        byID[summary.id] = summary
        continue
      }
      if existing.updatedAt < summary.updatedAt
        || (existing.updatedAt == summary.updatedAt && existing.createdAt < summary.createdAt)
      {
        byID[summary.id] = summary
      }
    }
    return Array(byID.values)
  }
}
