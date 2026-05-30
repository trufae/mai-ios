import Foundation
import UIKit

@MainActor
final class ResponseHaptics {
  private let streamSoftGenerator = UIImpactFeedbackGenerator(style: .soft)
  private let streamLightGenerator = UIImpactFeedbackGenerator(style: .light)
  private let streamMediumGenerator = UIImpactFeedbackGenerator(style: .medium)
  private let completionGenerator = UINotificationFeedbackGenerator()
  private let sidebarGenerator = UISelectionFeedbackGenerator()
  private var lastStreamFeedbackAt = Date.distantPast
  private var nextStreamInterval: TimeInterval
  private static let streamIntervalRange: ClosedRange<TimeInterval> = 0.09...0.28
  private static let streamIntensityRange: ClosedRange<Double> = 0.25...0.85

  init() {
    nextStreamInterval = Self.randomStreamInterval()
    streamSoftGenerator.prepare()
    streamLightGenerator.prepare()
    streamMediumGenerator.prepare()
    completionGenerator.prepare()
    sidebarGenerator.prepare()
  }

  func streamPacketReceived(force: Bool = false) {
    let now = Date()
    guard force || now.timeIntervalSince(lastStreamFeedbackAt) >= nextStreamInterval else {
      return
    }
    lastStreamFeedbackAt = now
    nextStreamInterval = Self.randomStreamInterval()

    let intensity = Self.randomStreamIntensity()
    let generator = streamGenerator(for: intensity)
    generator.prepare()
    generator.impactOccurred(intensity: intensity)
    generator.prepare()
  }

  func responseCompleted() {
    completionGenerator.prepare()
    completionGenerator.notificationOccurred(.success)
    completionGenerator.prepare()
  }

  func sidebarVisibilitySettled() {
    sidebarGenerator.prepare()
    sidebarGenerator.selectionChanged()
    sidebarGenerator.prepare()
  }

  private func streamGenerator(for intensity: CGFloat) -> UIImpactFeedbackGenerator {
    switch intensity {
    case ..<0.46:
      return streamSoftGenerator
    case ..<0.76:
      return streamLightGenerator
    default:
      return streamMediumGenerator
    }
  }

  private static func randomStreamInterval() -> TimeInterval {
    TimeInterval.random(in: streamIntervalRange)
  }

  private static func randomStreamIntensity() -> CGFloat {
    CGFloat(Double.random(in: streamIntensityRange))
  }
}
