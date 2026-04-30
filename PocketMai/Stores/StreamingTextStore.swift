import Combine
import Foundation

@MainActor
final class StreamingTextStore: ObservableObject {
  @Published private var texts: [UUID: String] = [:]

  private var pendingTexts: [UUID: String] = [:]
  private var publishTasks: [UUID: Task<Void, Never>] = [:]
  private var lastPublishAt: [UUID: Date] = [:]
  private static let publishInterval: TimeInterval = 0.12

  func text(for id: UUID) -> String? {
    texts[id]
  }

  func currentText(for id: UUID) -> String? {
    pendingTexts[id] ?? texts[id]
  }

  func enqueue(_ text: String, for id: UUID) {
    guard currentText(for: id) != text else { return }

    let now = Date()
    let lastPublish = lastPublishAt[id] ?? .distantPast
    let elapsed = now.timeIntervalSince(lastPublish)

    if elapsed >= Self.publishInterval {
      lastPublishAt[id] = now
      texts[id] = text
      return
    }

    pendingTexts[id] = text
    guard publishTasks[id] == nil else { return }

    let delay = max(0, Self.publishInterval - elapsed)
    publishTasks[id] = Task { @MainActor [weak self] in
      let nanoseconds = UInt64(delay * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      self.publishTasks[id] = nil
      guard let pending = self.pendingTexts.removeValue(forKey: id) else { return }
      self.lastPublishAt[id] = Date()
      if self.texts[id] != pending {
        self.texts[id] = pending
      }
    }
  }

  func clear(id: UUID) {
    pendingTexts.removeValue(forKey: id)
    lastPublishAt.removeValue(forKey: id)
    publishTasks[id]?.cancel()
    publishTasks.removeValue(forKey: id)
    texts.removeValue(forKey: id)
  }

  func removeAll() {
    for task in publishTasks.values {
      task.cancel()
    }
    publishTasks.removeAll()
    pendingTexts.removeAll()
    lastPublishAt.removeAll()
    texts.removeAll()
  }
}
