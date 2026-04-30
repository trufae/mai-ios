import Combine
import Foundation

@MainActor
final class StreamingText: ObservableObject {
  @Published fileprivate(set) var text: String?

  fileprivate func setText(_ text: String?) {
    self.text = text
  }
}

@MainActor
final class StreamingTextStore: ObservableObject {
  private var textObjects: [UUID: StreamingText] = [:]

  private var pendingTexts: [UUID: String] = [:]
  private var publishTasks: [UUID: Task<Void, Never>] = [:]
  private var lastPublishAt: [UUID: Date] = [:]
  private static let publishInterval: TimeInterval = 0.12

  func textObject(for id: UUID) -> StreamingText {
    if let object = textObjects[id] {
      return object
    }
    let object = StreamingText()
    textObjects[id] = object
    return object
  }

  func currentText(for id: UUID) -> String? {
    pendingTexts[id] ?? textObjects[id]?.text
  }

  func enqueue(_ text: String, for id: UUID) {
    guard currentText(for: id) != text else { return }

    let now = Date()
    let lastPublish = lastPublishAt[id] ?? .distantPast
    let elapsed = now.timeIntervalSince(lastPublish)

    if elapsed >= Self.publishInterval {
      lastPublishAt[id] = now
      textObject(for: id).setText(text)
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
      let object = self.textObject(for: id)
      if object.text != pending {
        object.setText(pending)
      }
    }
  }

  func clear(id: UUID) {
    pendingTexts.removeValue(forKey: id)
    lastPublishAt.removeValue(forKey: id)
    publishTasks[id]?.cancel()
    publishTasks.removeValue(forKey: id)
    textObjects[id]?.setText(nil)
    textObjects.removeValue(forKey: id)
  }

  func removeAll() {
    for task in publishTasks.values {
      task.cancel()
    }
    publishTasks.removeAll()
    pendingTexts.removeAll()
    lastPublishAt.removeAll()
    for object in textObjects.values {
      object.setText(nil)
    }
    textObjects.removeAll()
  }
}
