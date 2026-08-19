import Foundation

/// Accumulates token usage and generation speed per provider/model across the
/// whole app. Providers report every completed model call (chat turns, tool-loop
/// rounds, title generation), so totals reflect real consumption. Running totals
/// persist in UserDefaults; average speed is total output tokens divided by total
/// generation seconds, so long responses weigh more and the value converges over
/// time. Per-message stats are kept briefly so the tool loop can stamp them onto
/// the assistant message before it is persisted.
@MainActor
final class UsageStatsStore: ObservableObject {
  static let shared = UsageStatsStore()

  struct ModelTotals: Codable, Identifiable, Equatable, Sendable {
    var providerLabel: String
    var modelID: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedTokens: Int = 0
    var promptSeconds: TimeInterval = 0
    var generationSeconds: TimeInterval = 0
    var callCount: Int = 0
    var estimatedCallCount: Int = 0
    var lastTokensPerSecond: Double? = nil
    var lastUsedAt: Date = .distantPast

    var id: String { "\(providerLabel)|\(modelID)" }

    var averageTokensPerSecond: Double? {
      guard outputTokens > 0, generationSeconds > 0 else { return nil }
      return Double(outputTokens) / generationSeconds
    }

    var averagePromptTokensPerSecond: Double? {
      guard inputTokens > 0, promptSeconds > 0, estimatedCallCount == 0 else { return nil }
      return Double(inputTokens) / promptSeconds
    }
  }

  @Published private(set) var totals: [ModelTotals] = []

  private var pendingByMessageID: [UUID: GenerationStats] = [:]
  private var pendingOrder: [UUID] = []
  private static let pendingLimit = 64
  private static let defaultsKey = "usageStats.totals.v1"

  private init() {
    totals = Self.loadTotals()
  }

  static func record(_ stats: GenerationStats, assistantMessageID: UUID?) {
    shared.record(stats, assistantMessageID: assistantMessageID)
  }

  func record(_ stats: GenerationStats, assistantMessageID: UUID?) {
    guard stats.inputTokens > 0 || stats.outputTokens > 0 else { return }
    var entry =
      totals.first { $0.providerLabel == stats.providerLabel && $0.modelID == stats.modelID }
      ?? ModelTotals(providerLabel: stats.providerLabel, modelID: stats.modelID)
    entry.inputTokens += stats.inputTokens
    entry.outputTokens += stats.outputTokens
    entry.cachedTokens += stats.cachedTokens
    entry.promptSeconds += stats.promptSeconds
    entry.generationSeconds += stats.generationSeconds
    entry.callCount += stats.callCount
    if stats.tokensEstimated {
      entry.estimatedCallCount += stats.callCount
    }
    entry.lastTokensPerSecond = stats.tokensPerSecond ?? entry.lastTokensPerSecond
    entry.lastUsedAt = Date()
    if let index = totals.firstIndex(where: { $0.id == entry.id }) {
      totals[index] = entry
    } else {
      totals.append(entry)
    }
    persistTotals()

    if let assistantMessageID {
      if var pending = pendingByMessageID[assistantMessageID] {
        pending.merge(stats)
        pendingByMessageID[assistantMessageID] = pending
      } else {
        pendingByMessageID[assistantMessageID] = stats
        pendingOrder.append(assistantMessageID)
        if pendingOrder.count > Self.pendingLimit {
          pendingByMessageID.removeValue(forKey: pendingOrder.removeFirst())
        }
      }
    }
  }

  /// Accumulated stats for an assistant message across all tool-loop rounds so far.
  func pendingStats(for messageID: UUID) -> GenerationStats? {
    pendingByMessageID[messageID]
  }

  func reset() {
    totals = []
    persistTotals()
  }

  func remove(id: String) {
    totals.removeAll { $0.id == id }
    persistTotals()
  }

  private func persistTotals() {
    guard let data = try? JSONEncoder().encode(totals) else { return }
    UserDefaults.standard.set(data, forKey: Self.defaultsKey)
  }

  private static func loadTotals() -> [ModelTotals] {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode([ModelTotals].self, from: data)
    else {
      return []
    }
    return decoded
  }
}
