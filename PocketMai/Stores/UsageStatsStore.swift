import Foundation
import MaiCore

/// Accumulates token usage and generation speed per provider/model across the
/// whole app. Providers report every completed model call (chat turns, tool-loop
/// rounds, title generation), so totals reflect real consumption. The arithmetic
/// is MaiCore's `ModelUsageLedger`, the same code behind the pmai REPL's
/// `/stats`; this store adds the main-actor publishing SwiftUI needs, the
/// UserDefaults persistence PocketMai has always used, and the per-message
/// stats kept briefly so the tool loop can stamp them onto the assistant
/// message before it is persisted.
@MainActor
final class UsageStatsStore: ObservableObject {
  static let shared = UsageStatsStore()

  typealias ModelTotals = ModelUsageTotals

  @Published private(set) var ledger: ModelUsageLedger

  var totals: [ModelTotals] { ledger.totals }

  private var pendingByMessageID: [UUID: GenerationStats] = [:]
  private var pendingOrder: [UUID] = []
  private static let pendingLimit = 64
  private static let defaultsKey = "usageStats.totals.v1"

  private init() {
    ledger = Self.loadLedger()
  }

  static func record(_ stats: GenerationStats, assistantMessageID: UUID?) {
    shared.record(stats, assistantMessageID: assistantMessageID)
  }

  func record(_ stats: GenerationStats, assistantMessageID: UUID?) {
    guard stats.inputTokens > 0 || stats.outputTokens > 0 else { return }
    ledger.record(stats)
    persistLedger()

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
    ledger.reset()
    persistLedger()
  }

  func remove(id: String) {
    ledger.remove(id: id)
    persistLedger()
  }

  func remove(providerLabel: String) {
    ledger.remove(providerLabel: providerLabel)
    persistLedger()
  }

  private func persistLedger() {
    guard let data = try? ledger.encoded() else { return }
    UserDefaults.standard.set(data, forKey: Self.defaultsKey)
  }

  /// Totals saved by any earlier release decode too: the ledger reads the
  /// numeric dates they stored as well as the ISO 8601 dates written now.
  private static func loadLedger() -> ModelUsageLedger {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
      let decoded = try? ModelUsageLedger.decode(data)
    else {
      return ModelUsageLedger()
    }
    return decoded
  }
}
