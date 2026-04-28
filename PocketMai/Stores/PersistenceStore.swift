import Foundation

struct PersistedConversations: Codable {
  var conversations: [Conversation]
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

  private var settingsURL: URL {
    baseURL.appendingPathComponent("settings.json")
  }

  func loadConversations() -> [Conversation] {
    guard let data = try? Data(contentsOf: conversationsURL) else { return [] }
    let decoder = makeDecoder()
    if let envelope = try? decoder.decode(PersistedConversations.self, from: data) {
      return envelope.conversations
    }
    return (try? decoder.decode([Conversation].self, from: data)) ?? []
  }

  func saveConversations(_ conversations: [Conversation]) {
    let visible = conversations.filter { !$0.isIncognito }
    let envelope = PersistedConversations(conversations: visible)
    let url = conversationsURL
    let dir = baseURL
    let delay = debounce
    writeQueue.async { [weak self] in
      guard let self else { return }
      self.pendingConversations?.cancel()
      let item = DispatchWorkItem { Self.persist(envelope, to: url, dir: dir) }
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

  private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
