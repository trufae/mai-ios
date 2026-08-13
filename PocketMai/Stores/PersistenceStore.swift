import Foundation

struct PersistedConversations: Codable {
  var conversations: [Conversation]
}

private struct PersistedConversationIndex: Codable {
  var version = 2
  var ids: [UUID]
  var summaries: [ConversationSummary]?
}

private struct PersistedRecentConversationCache: Codable {
  var version = 1
  var entries: [PersistedRecentConversationEntry]
}

private struct PersistedLaunchConversationCache: Codable {
  var version = 1
  var summaries: [ConversationSummary]
}

private struct PersistedRecentConversationEntry: Codable {
  var filename: String
  var summary: ConversationSummary
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

  var recentConversationsCacheURL: URL {
    conversationsDirectoryURL.appendingPathComponent("recent.json")
  }
}

struct CorruptedConversationRecoveryResult: Sendable {
  let recoveredConversations: [Conversation]
  let remainingCount: Int
}

struct CorruptedConversationExportResult: Sendable {
  let url: URL?
  let errorMessage: String?
}

struct CorruptedConversationDocument: Identifiable, Sendable {
  let id: String
  let filename: String
  let location: String
  let contents: String
  let isValidJSON: Bool
  let byteCount: Int
}

struct CorruptedConversationDeletionResult: Sendable {
  let deleted: Bool
  let errorMessage: String?
}

final class PersistenceStore: @unchecked Sendable {
  private let fileManager: FileManager
  private let localBaseURL: URL
  private let iCloudFallbackBaseURL: URL
  private let preparationLock = NSLock()
  private let quarantineLock = NSLock()
  private let writeQueue = DispatchQueue(
    label: "dev.mai.chat.persistence", qos: .userInitiated)
  private let debounce: TimeInterval = 0.4
  private var didPrepareStorage = false
  // Touched only from writeQueue; serial access guarantees thread-safety.
  private var pendingSettings: DispatchWorkItem?
  private var pendingConversations: DispatchWorkItem?
  private var pendingDrafts: DispatchWorkItem?
  private var persistedConversationsByID: [UUID: Conversation] = [:]

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    localBaseURL = PocketMaiDirectories.appDataURL
    iCloudFallbackBaseURL = PocketMaiDirectories.appDataURL
      .appendingPathComponent("iCloud-conversations", isDirectory: true)
  }

  private func prepareForAccess() {
    preparationLock.lock()
    defer { preparationLock.unlock() }
    guard !didPrepareStorage else { return }
    PocketMaiDirectories.prepareLaunchStorage(fileManager: fileManager)
    try? fileManager.createDirectory(at: localBaseURL, withIntermediateDirectories: true)
    didPrepareStorage = true
  }

  private var localStorageURLs: ConversationStorageURLs {
    ConversationStorageURLs(baseURL: localBaseURL)
  }

  private func iCloudStorageURLs(migrateFallback: Bool = true) -> ConversationStorageURLs {
    if let baseURL = resolvedICloudBaseURL() {
      if migrateFallback {
        migrateFallbackICloudConversationsIfNeeded(to: baseURL)
      }
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

  private var launchConversationCacheURL: URL {
    localBaseURL.appendingPathComponent("recent-conversations.json")
  }

  func loadConversations() -> [Conversation] {
    prepareForAccess()
    var conversations = loadConversations(from: localStorageURLs)
    conversations.append(contentsOf: loadConversations(from: iCloudStorageURLs()))
    conversations = Self.mergedConversations(conversations)
    seedPersistedSnapshot(conversations)
    return conversations
  }

  func loadConversationSummaries() -> [ConversationSummary] {
    prepareForAccess()
    let summaries = Self.mergedSummaries(
      loadConversationSummaries(from: localStorageURLs)
        + loadConversationSummaries(from: iCloudStorageURLs()))
    Self.persistLaunchConversationCache(summaries, to: launchConversationCacheURL)
    return summaries
  }

  func loadRecentConversationSummaries(
    limit: Int = ConversationSummary.recentCacheLimit
  ) -> [ConversationSummary] {
    prepareForAccess()
    return ConversationSummary.mostRecent(
      Self.mergedSummaries(
        loadRecentConversationSummaries(from: localStorageURLs, limit: limit)
          + loadRecentConversationSummaries(
            from: iCloudStorageURLs(migrateFallback: false),
            limit: limit)),
      limit: limit)
  }

  /// Loads only the device-local launch cache. Keep this separate from the merged loader so the
  /// welcome screen never waits for iCloud container discovery or coordinated cloud file access.
  func loadLocalRecentConversationSummaries(
    limit: Int = ConversationSummary.recentCacheLimit
  ) -> [ConversationSummary] {
    prepareForAccess()
    if let data = try? Data(contentsOf: launchConversationCacheURL),
      let cache = try? makeDecoder().decode(PersistedLaunchConversationCache.self, from: data)
    {
      return ConversationSummary.mostRecent(cache.summaries, limit: limit)
    }
    return loadRecentConversationSummaries(from: localStorageURLs, limit: limit)
  }

  func loadConversation(id: UUID) -> Conversation? {
    prepareForAccess()
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

  func corruptedConversationCount() -> Int {
    prepareForAccess()
    let locations = corruptedConversationStorageLocations()
    return writeQueue.sync {
      corruptedConversationFileURLs(in: locations).count
    }
  }

  func corruptedConversationDocuments() -> [CorruptedConversationDocument] {
    prepareForAccess()
    let locations = corruptedConversationStorageLocations()
    return writeQueue.sync {
      corruptedConversationFileURLs(in: locations).compactMap { file in
        guard let data = try? Data(contentsOf: file.url) else { return nil }
        let rendered = Self.renderCorruptedConversationData(data)
        return CorruptedConversationDocument(
          id: file.identifier,
          filename: file.url.lastPathComponent,
          location: file.location.displayName,
          contents: rendered.contents,
          isValidJSON: rendered.isValidJSON,
          byteCount: data.count)
      }
    }
  }

  func deleteCorruptedConversation(id: String) -> CorruptedConversationDeletionResult {
    prepareForAccess()
    let locations = corruptedConversationStorageLocations()
    return writeQueue.sync {
      guard
        let file = corruptedConversationFileURLs(in: locations).first(where: {
          $0.identifier == id
        })
      else {
        return CorruptedConversationDeletionResult(
          deleted: false, errorMessage: "The corrupted chat file no longer exists.")
      }
      do {
        try fileManager.removeItem(at: file.url)
        return CorruptedConversationDeletionResult(deleted: true, errorMessage: nil)
      } catch {
        return CorruptedConversationDeletionResult(
          deleted: false,
          errorMessage: "Could not delete the corrupted chat: \(error.localizedDescription)")
      }
    }
  }

  /// Deletes only conversation files named by an explicit, confirmed user action.
  /// Quarantined files are deliberately excluded and have their own confirmation flow.
  func deleteConversationFiles(ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      let candidates = [
        self.localStorageURLs,
        self.iCloudStorageURLs(migrateFallback: false),
        ConversationStorageURLs(baseURL: self.iCloudFallbackBaseURL),
      ]
      var seen = Set<URL>()
      for storage in candidates
      where seen.insert(storage.baseURL.standardizedFileURL).inserted {
        for id in ids {
          let url = Self.conversationFileURL(
            for: id, in: storage.conversationsDirectoryURL)
          try? self.fileManager.removeItem(at: url)
        }
      }
      self.persistedConversationsByID = self.persistedConversationsByID.filter {
        !ids.contains($0.key)
      }
    }
  }

  func exportCorruptedConversationsArchive() -> CorruptedConversationExportResult {
    prepareForAccess()
    let locations = corruptedConversationStorageLocations()
    return writeQueue.sync {
      let files = corruptedConversationFileURLs(in: locations)
      guard !files.isEmpty else {
        return CorruptedConversationExportResult(
          url: nil, errorMessage: "There are no corrupted chats to export.")
      }

      var entries: [(path: String, data: Data)] = []
      for file in files {
        guard let data = try? Data(contentsOf: file.url) else { continue }
        entries.append(("\(file.location.archiveDirectory)/\(file.url.lastPathComponent)", data))
      }
      guard !entries.isEmpty else {
        return CorruptedConversationExportResult(
          url: nil, errorMessage: "Could not read the corrupted chat files.")
      }

      do {
        let filename = "PocketMai-corrupted-chats-\(Int(Date().timeIntervalSince1970))"
        let url = try ConversationExportFiles.url(filename: filename, fileExtension: "zip")
        try MiniZip.write(entries: entries, to: url)
        return CorruptedConversationExportResult(url: url, errorMessage: nil)
      } catch {
        return CorruptedConversationExportResult(
          url: nil,
          errorMessage: "Could not create the recovery archive: \(error.localizedDescription)")
      }
    }
  }

  func recoverCorruptedConversations() -> CorruptedConversationRecoveryResult {
    prepareForAccess()
    let locations = corruptedConversationStorageLocations()
    return writeQueue.sync {
      var recovered: [Conversation] = []
      for location in locations {
        recovered.append(contentsOf: recoverCorruptedConversations(in: location.storage))
      }
      return CorruptedConversationRecoveryResult(
        recoveredConversations: recovered,
        remainingCount: corruptedConversationFileURLs(in: locations).count)
    }
  }

  private func loadConversations(from storage: ConversationStorageURLs) -> [Conversation] {
    if let conversations = loadIndexedConversations(from: storage) {
      return conversations
    }

    let legacyConversations = loadLegacyConversations(from: storage)
    let conversations = Self.mergedConversations(
      legacyConversations + loadUnindexedConversations(from: storage))
    if !conversations.isEmpty {
      let persisted = Self.persistConversations(
        conversations,
        ids: conversations.map(\.id),
        summaries: conversations.map(ConversationSummary.init),
        storage: storage,
        writeIndex: true)
      if persisted, !legacyConversations.isEmpty {
        try? fileManager.removeItem(at: storage.conversationsURL)
      }
    }
    return conversations
  }

  private func loadConversationSummaries(from storage: ConversationStorageURLs)
    -> [ConversationSummary]
  {
    guard let data = try? Data(contentsOf: storage.conversationsIndexURL),
      let index = try? makeDecoder().decode(PersistedConversationIndex.self, from: data)
    else {
      if fileManager.fileExists(atPath: storage.conversationsIndexURL.path) {
        _ = quarantineConversationFile(at: storage.conversationsIndexURL)
      }
      let legacyConversations = loadLegacyConversations(from: storage)
      let conversations = Self.mergedConversations(
        legacyConversations + loadUnindexedConversations(from: storage))
      guard !conversations.isEmpty else { return [] }
      let summaries = conversations.map(ConversationSummary.init)
      let persisted = Self.persistConversations(
        conversations,
        ids: conversations.map(\.id),
        summaries: summaries,
        storage: storage,
        writeIndex: true)
      if persisted, !legacyConversations.isEmpty {
        try? fileManager.removeItem(at: storage.conversationsURL)
      }
      return summaries
    }
    if let summaries = index.summaries {
      let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
      let ordered = index.ids.compactMap { byID[$0] }
      let unindexed = loadUnindexedConversations(from: storage, excluding: Set(index.ids))
      let validated = Self.mergedSummaries(
        validatedConversationSummaries(ordered, in: storage)
          + unindexed.map(ConversationSummary.init))
      if validated.count != ordered.count || !unindexed.isEmpty {
        _ = Self.persistConversations(
          unindexed,
          ids: validated.map(\.id),
          summaries: validated,
          storage: storage,
          writeIndex: true)
      } else {
        _ = Self.persistRecentConversationCache(summaries: validated, storage: storage)
      }
      return validated
    }
    return []
  }

  private func loadRecentConversationSummaries(
    from storage: ConversationStorageURLs,
    limit: Int
  ) -> [ConversationSummary] {
    guard let data = try? Data(contentsOf: storage.recentConversationsCacheURL),
      let cache = try? makeDecoder().decode(PersistedRecentConversationCache.self, from: data)
    else {
      return []
    }
    let summaries = cache.entries.compactMap { entry -> ConversationSummary? in
      let expectedFilename = Self.conversationFilename(for: entry.summary.id)
      guard entry.filename == expectedFilename else { return nil }
      let url = storage.conversationsDirectoryURL.appendingPathComponent(entry.filename)
      guard fileManager.fileExists(atPath: url.path) else { return nil }
      return entry.summary
    }
    return ConversationSummary.mostRecent(summaries, limit: limit)
  }

  private func loadConversation(id: UUID, from storage: ConversationStorageURLs) -> Conversation? {
    let url = Self.conversationFileURL(for: id, in: storage.conversationsDirectoryURL)
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let conversation = try? makeDecoder().decode(Conversation.self, from: data) else {
      _ = quarantineConversationFile(at: url)
      return nil
    }
    return conversation
  }

  private struct CorruptedConversationStorage {
    let archiveDirectory: String
    let displayName: String
    let storage: ConversationStorageURLs
  }

  private struct CorruptedConversationFile {
    let url: URL
    let location: CorruptedConversationStorage

    var identifier: String {
      "\(location.archiveDirectory)/\(url.lastPathComponent)"
    }
  }

  private func corruptedConversationStorageLocations() -> [CorruptedConversationStorage] {
    let local = localStorageURLs
    let iCloud = iCloudStorageURLs(migrateFallback: false)
    let fallback = ConversationStorageURLs(baseURL: iCloudFallbackBaseURL)
    let candidates = [
      CorruptedConversationStorage(
        archiveDirectory: "on-device", displayName: "On This Device", storage: local),
      CorruptedConversationStorage(
        archiveDirectory: "icloud", displayName: "iCloud", storage: iCloud),
      CorruptedConversationStorage(
        archiveDirectory: "icloud-fallback", displayName: "iCloud Fallback", storage: fallback),
    ]
    var seen = Set<URL>()
    return candidates.filter { seen.insert($0.storage.baseURL.standardizedFileURL).inserted }
  }

  private func corruptedConversationFileURLs(
    in locations: [CorruptedConversationStorage]
  ) -> [CorruptedConversationFile] {
    locations.flatMap { location in
      corruptedConversationFileURLs(in: location.storage).map {
        CorruptedConversationFile(url: $0, location: location)
      }
    }
  }

  private func corruptedConversationFileURLs(in storage: ConversationStorageURLs) -> [URL] {
    var files =
      ((try? fileManager.contentsOfDirectory(
        at: storage.conversationsDirectoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])) ?? [])
      .filter {
        $0.pathExtension == "corrupt" && $0.deletingPathExtension().pathExtension == "json"
      }
    let legacyFiles =
      ((try? fileManager.contentsOfDirectory(
        at: storage.baseURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])) ?? [])
      .filter {
        $0.pathExtension == "corrupt" && $0.deletingPathExtension().pathExtension == "json"
      }
    files.append(contentsOf: legacyFiles)
    return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func renderCorruptedConversationData(_ data: Data) -> (
    contents: String, isValidJSON: Bool
  ) {
    if let object = try? JSONSerialization.jsonObject(with: data),
      let prettyData = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      let text = String(data: prettyData, encoding: .utf8)
    {
      return (text, true)
    }
    if let text = String(data: data, encoding: .utf8) {
      return (text, false)
    }
    return (data.base64EncodedString(options: [.lineLength76Characters]), false)
  }

  private func quarantineConversationFile(at source: URL) -> URL? {
    quarantineLock.lock()
    defer { quarantineLock.unlock() }
    guard fileManager.fileExists(atPath: source.path) else { return nil }

    let directory = source.deletingLastPathComponent()
    let stem = source.deletingPathExtension().lastPathComponent
    var destination = source.appendingPathExtension("corrupt")
    var suffix = 2
    while fileManager.fileExists(atPath: destination.path) {
      destination = directory.appendingPathComponent("\(stem)-\(suffix).json.corrupt")
      suffix += 1
    }
    do {
      try fileManager.moveItem(at: source, to: destination)
      return destination
    } catch {
      return nil
    }
  }

  private func recoverCorruptedConversations(in storage: ConversationStorageURLs) -> [Conversation]
  {
    let decoder = makeDecoder()
    var moved: [(source: URL, destination: URL, conversation: Conversation)] = []

    for source in corruptedConversationFileURLs(in: storage) {
      guard let data = try? Data(contentsOf: source),
        let conversation = try? decoder.decode(Conversation.self, from: data)
      else {
        continue
      }
      let destination = Self.conversationFileURL(
        for: conversation.id, in: storage.conversationsDirectoryURL)
      guard !fileManager.fileExists(atPath: destination.path) else { continue }
      do {
        try fileManager.moveItem(at: source, to: destination)
        moved.append((source, destination, conversation))
      } catch {
        continue
      }
    }

    guard !moved.isEmpty else { return [] }
    let conversations = moved.map(\.conversation)
    guard restoreRecoveredConversationsToIndex(conversations, in: storage) else {
      for entry in moved.reversed() {
        try? fileManager.moveItem(at: entry.destination, to: entry.source)
      }
      return []
    }
    return conversations
  }

  private func restoreRecoveredConversationsToIndex(
    _ recovered: [Conversation], in storage: ConversationStorageURLs
  ) -> Bool {
    guard let data = try? Data(contentsOf: storage.conversationsIndexURL),
      let index = try? makeDecoder().decode(PersistedConversationIndex.self, from: data)
    else {
      let conversations = Self.mergedConversations(
        loadLegacyConversations(from: storage)
          + loadUnindexedConversations(from: storage)
          + recovered)
      return Self.persistConversations(
        conversations,
        ids: conversations.map(\.id),
        summaries: conversations.map(ConversationSummary.init),
        storage: storage,
        writeIndex: true)
    }

    var ids: [UUID] = []
    for id in index.ids where !ids.contains(id) {
      ids.append(id)
    }
    var summaries: [UUID: ConversationSummary] = [:]
    for summary in index.summaries ?? [] {
      summaries[summary.id] = summary
    }
    for id in ids where summaries[id] == nil {
      guard let conversation = loadConversation(id: id, from: storage) else { return false }
      summaries[id] = ConversationSummary(conversation: conversation)
    }
    for conversation in recovered {
      if !ids.contains(conversation.id) {
        ids.append(conversation.id)
      }
      summaries[conversation.id] = ConversationSummary(conversation: conversation)
    }
    return Self.persistConversationIndex(
      ids: ids,
      summaries: ids.compactMap { summaries[$0] },
      storage: storage)
  }

  private func loadUnindexedConversations(
    from storage: ConversationStorageURLs,
    excluding indexedIDs: Set<UUID> = []
  ) -> [Conversation] {
    let indexedFilenames = Set(indexedIDs.map(Self.conversationFilename(for:)))
    return
      ((try? fileManager.contentsOfDirectory(
        at: storage.conversationsDirectoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])) ?? [])
      .filter {
        $0.pathExtension == "json"
          && $0.lastPathComponent != storage.conversationsIndexURL.lastPathComponent
          && $0.lastPathComponent != storage.recentConversationsCacheURL.lastPathComponent
          && !indexedFilenames.contains($0.lastPathComponent)
      }
      .compactMap { url in
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let conversation = try? makeDecoder().decode(Conversation.self, from: data) else {
          _ = quarantineConversationFile(at: url)
          return nil
        }
        return conversation
      }
  }

  private func loadIndexedConversations(from storage: ConversationStorageURLs) -> [Conversation]? {
    guard let data = try? Data(contentsOf: storage.conversationsIndexURL),
      let index = try? makeDecoder().decode(PersistedConversationIndex.self, from: data)
    else {
      if fileManager.fileExists(atPath: storage.conversationsIndexURL.path) {
        _ = quarantineConversationFile(at: storage.conversationsIndexURL)
      }
      return nil
    }

    let decoder = makeDecoder()
    var needsRepair = false
    var canRepairIndex = true
    var conversations = index.ids.compactMap { id -> Conversation? in
      let url = Self.conversationFileURL(for: id, in: storage.conversationsDirectoryURL)
      guard let data = try? Data(contentsOf: url) else {
        if fileManager.fileExists(atPath: url.path) {
          canRepairIndex = false
        } else {
          needsRepair = true
        }
        return nil
      }
      guard let conversation = try? decoder.decode(Conversation.self, from: data) else {
        if quarantineConversationFile(at: url) != nil {
          needsRepair = true
        } else {
          canRepairIndex = false
        }
        return nil
      }
      return conversation
    }
    let unindexed = loadUnindexedConversations(from: storage, excluding: Set(index.ids))
    conversations = Self.mergedConversations(conversations + unindexed)
    if canRepairIndex && (needsRepair || !unindexed.isEmpty) {
      _ = Self.persistConversationIndex(
        ids: conversations.map(\.id),
        summaries: conversations.map(ConversationSummary.init),
        storage: storage)
    }
    return conversations
  }

  private func loadLegacyConversations(from storage: ConversationStorageURLs) -> [Conversation] {
    guard let data = try? Data(contentsOf: storage.conversationsURL) else { return [] }
    let decoder = makeDecoder()
    if let envelope = try? decoder.decode(PersistedConversations.self, from: data) {
      return envelope.conversations
    }
    if let conversations = try? decoder.decode([Conversation].self, from: data) {
      return conversations
    }
    _ = quarantineConversationFile(at: storage.conversationsURL)
    return []
  }

  func saveConversations(_ conversations: [Conversation]) {
    let snapshot = conversations
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      let localStorage = self.localStorageURLs
      let iCloudStorage = self.iCloudStorageURLs()
      let byID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
      let localConversations = snapshot.filter { $0.folderID != ConversationFolder.iCloudID }
      let iCloudConversations = snapshot.filter { $0.folderID == ConversationFolder.iCloudID }
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
          Self.persistLaunchConversationCache(
            snapshot.map(ConversationSummary.init),
            to: self.launchConversationCacheURL)
        }
      }
      self.pendingConversations = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func saveLoadedConversations(
    _ conversations: [Conversation],
    summaries: [ConversationSummary]
  ) {
    let conversationSnapshot = conversations
    let summarySnapshot = summaries
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      let localStorage = self.localStorageURLs
      let iCloudStorage = self.iCloudStorageURLs()
      let loadedByID = Dictionary(uniqueKeysWithValues: conversationSnapshot.map { ($0.id, $0) })
      let localSummaries = self.persistableSummaries(
        summarySnapshot.filter { $0.folderID != ConversationFolder.iCloudID },
        loadedIDs: Set(loadedByID.keys),
        storage: localStorage)
      let iCloudSummaries = self.persistableSummaries(
        summarySnapshot.filter { $0.folderID == ConversationFolder.iCloudID },
        loadedIDs: Set(loadedByID.keys),
        storage: iCloudStorage)
      let localConversations = conversationSnapshot.filter {
        $0.folderID != ConversationFolder.iCloudID
      }
      let iCloudConversations = conversationSnapshot.filter {
        $0.folderID == ConversationFolder.iCloudID
      }

      self.pendingConversations?.cancel()
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let persistedLocal = Self.persistConversations(
          localConversations,
          ids: localSummaries.map(\.id),
          summaries: localSummaries,
          storage: localStorage,
          writeIndex: true
        )
        let persistedICloud = Self.persistConversations(
          iCloudConversations,
          ids: iCloudSummaries.map(\.id),
          summaries: iCloudSummaries,
          storage: iCloudStorage,
          writeIndex: true
        )
        if persistedLocal && persistedICloud {
          let liveIDs = Set(localSummaries.map(\.id) + iCloudSummaries.map(\.id))
          self.persistedConversationsByID = self.persistedConversationsByID.filter {
            liveIDs.contains($0.key)
          }
          for conversation in conversationSnapshot {
            self.persistedConversationsByID[conversation.id] = conversation
          }
          Self.persistLaunchConversationCache(
            summarySnapshot,
            to: self.launchConversationCacheURL)
        }
      }
      self.pendingConversations = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func saveConversationSummaries(_ summaries: [ConversationSummary]) {
    let summarySnapshot = summaries
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      let localStorage = self.localStorageURLs
      let iCloudStorage = self.iCloudStorageURLs()
      let localSummaries = self.persistableSummaries(
        summarySnapshot.filter { $0.folderID != ConversationFolder.iCloudID },
        loadedIDs: [],
        storage: localStorage)
      let iCloudSummaries = self.persistableSummaries(
        summarySnapshot.filter { $0.folderID == ConversationFolder.iCloudID },
        loadedIDs: [],
        storage: iCloudStorage)
      let persistedLocal = Self.persistConversationIndex(
        ids: localSummaries.map(\.id),
        summaries: localSummaries,
        storage: localStorage)
      let persistedICloud = Self.persistConversationIndex(
        ids: iCloudSummaries.map(\.id),
        summaries: iCloudSummaries,
        storage: iCloudStorage)
      if persistedLocal && persistedICloud {
        Self.persistLaunchConversationCache(
          summarySnapshot,
          to: self.launchConversationCacheURL)
      }
    }
  }

  func loadSettings() -> AppSettings {
    prepareForAccess()
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
      self.prepareForAccess()
      self.pendingSettings?.cancel()
      let item = DispatchWorkItem { Self.persist(snapshot, to: url, dir: dir) }
      self.pendingSettings = item
      self.writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  func loadDrafts() -> [UUID: String] {
    prepareForAccess()
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
    let drafts = drafts
    let url = draftsURL
    let dir = localBaseURL
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.prepareForAccess()
      self.pendingDrafts?.cancel()
      let item = DispatchWorkItem {
        let snapshot = PersistedDrafts(
          drafts: Dictionary(uniqueKeysWithValues: drafts.map { ($0.key.uuidString, $0.value) }))
        Self.persist(snapshot, to: url, dir: dir)
      }
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

  private static func persistLaunchConversationCache(
    _ summaries: [ConversationSummary],
    to url: URL
  ) {
    do {
      let cache = PersistedLaunchConversationCache(
        summaries: ConversationSummary.mostRecent(summaries))
      let data = try makeEncoder().encode(cache)
      if (try? Data(contentsOf: url)) == data {
        return
      }
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic])
    } catch {
      // The full indexes remain authoritative and will refresh this cache on the next load/save.
    }
  }

  private func validatedConversationSummaries(
    _ summaries: [ConversationSummary],
    in storage: ConversationStorageURLs
  ) -> [ConversationSummary] {
    summaries.filter { summary in
      let url = Self.conversationFileURL(for: summary.id, in: storage.conversationsDirectoryURL)
      return fileManager.fileExists(atPath: url.path)
    }
  }

  private func persistableSummaries(
    _ summaries: [ConversationSummary],
    loadedIDs: Set<UUID>,
    storage: ConversationStorageURLs
  ) -> [ConversationSummary] {
    summaries.filter { summary in
      if loadedIDs.contains(summary.id) {
        return true
      }
      let url = Self.conversationFileURL(for: summary.id, in: storage.conversationsDirectoryURL)
      return fileManager.fileExists(atPath: url.path)
    }
  }

  private static func persistConversationIndex(
    ids: [UUID],
    summaries: [ConversationSummary],
    storage: ConversationStorageURLs
  ) -> Bool {
    do {
      let fileManager = FileManager.default
      try fileManager.createDirectory(
        at: storage.conversationsDirectoryURL, withIntermediateDirectories: true)
      let encoder = makeEncoder()
      let index = PersistedConversationIndex(ids: ids, summaries: summaries)
      let data = try encoder.encode(index)
      try data.write(to: storage.conversationsIndexURL, options: [.atomic])
      try writeRecentConversationCache(summaries: summaries, storage: storage, encoder: encoder)
      return true
    } catch {
      return false
    }
  }

  @discardableResult
  private static func persistRecentConversationCache(
    summaries: [ConversationSummary],
    storage: ConversationStorageURLs,
    encoder: JSONEncoder = makeEncoder()
  ) -> Bool {
    do {
      try writeRecentConversationCache(summaries: summaries, storage: storage, encoder: encoder)
      return true
    } catch {
      return false
    }
  }

  private static func writeRecentConversationCache(
    summaries: [ConversationSummary],
    storage: ConversationStorageURLs,
    encoder: JSONEncoder
  ) throws {
    let entries = ConversationSummary.mostRecent(summaries).map {
      PersistedRecentConversationEntry(
        filename: conversationFilename(for: $0.id),
        summary: $0)
    }
    let cache = PersistedRecentConversationCache(entries: entries)
    let data = try encoder.encode(cache)
    if (try? Data(contentsOf: storage.recentConversationsCacheURL)) == data {
      return
    }
    try data.write(to: storage.recentConversationsCacheURL, options: [.atomic])
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

      if writeIndex {
        let index = PersistedConversationIndex(ids: ids, summaries: summaries)
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: [.atomic])
        try writeRecentConversationCache(summaries: summaries, storage: storage, encoder: encoder)
      }
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
    // Keep the fallback store after copying. It may contain quarantined or temporarily unreadable
    // files that were intentionally excluded from the decoded migration set.
    _ = persisted
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
