import Foundation
import UIKit

@MainActor
final class ResponseHaptics {
  private let streamGenerator = UIImpactFeedbackGenerator(style: .light)
  private let completionGenerator = UIImpactFeedbackGenerator(style: .medium)
  private var lastStreamFeedbackAt = Date.distantPast
  private static let minimumStreamInterval: TimeInterval = 0.18

  init() {
    streamGenerator.prepare()
    completionGenerator.prepare()
  }

  func streamPacketReceived(force: Bool = false) {
    let now = Date()
    guard force || now.timeIntervalSince(lastStreamFeedbackAt) >= Self.minimumStreamInterval else {
      return
    }
    lastStreamFeedbackAt = now
    streamGenerator.prepare()
    streamGenerator.impactOccurred()
    streamGenerator.prepare()
  }

  func responseCompleted() {
    completionGenerator.prepare()
    completionGenerator.impactOccurred()
    completionGenerator.prepare()
  }
}
