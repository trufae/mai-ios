import Foundation

struct PersistedConversations: Codable {
  var conversations: [Conversation]
}

final class PersistenceStore: @unchecked Sendable {
  private let fileManager: FileManager
  private let baseURL: URL
  private let writeQueue = DispatchQueue(
    label: "dev.mai.chat.persistence", qos: .userInitiated)

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let documents =
      fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    baseURL = documents.appendingPathComponent("MAIChat", isDirectory: true)
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
    writeQueue.async {
      Self.persist(envelope, to: url, dir: dir)
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
    writeQueue.async {
      Self.persist(snapshot, to: url, dir: dir)
    }
  }

  private static func persist<T: Encodable>(_ value: T, to url: URL, dir: URL) {
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
