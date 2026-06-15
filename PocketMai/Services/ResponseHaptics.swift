import Foundation
import AudioToolbox
import UIKit

@MainActor
final class ResponseHaptics {
  private let streamSoftGenerator = UIImpactFeedbackGenerator(style: .soft)
  private let streamLightGenerator = UIImpactFeedbackGenerator(style: .light)
  private let streamMediumGenerator = UIImpactFeedbackGenerator(style: .medium)
  private let thinkingGenerator = UIImpactFeedbackGenerator(style: .rigid)
  private let completionGenerator = UINotificationFeedbackGenerator()
  private let sidebarGenerator = UISelectionFeedbackGenerator()
  private var lastStreamFeedbackAt = Date.distantPast
  private var nextStreamInterval: TimeInterval
  private var lastThinkingFeedbackAt = Date.distantPast
  private var nextThinkingInterval: TimeInterval
  private static let streamIntervalRange: ClosedRange<TimeInterval> = 0.09...0.28
  private static let streamIntensityRange: ClosedRange<Double> = 0.25...0.85
  private static let thinkingIntervalRange: ClosedRange<TimeInterval> = 0.18...0.42
  private static let thinkingIntensityRange: ClosedRange<Double> = 0.12...0.4

  init() {
    nextStreamInterval = Self.randomStreamInterval()
    nextThinkingInterval = Self.randomThinkingInterval()
    streamSoftGenerator.prepare()
    streamLightGenerator.prepare()
    streamMediumGenerator.prepare()
    thinkingGenerator.prepare()
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

  func thinkingTokenReceived() {
    let now = Date()
    guard now.timeIntervalSince(lastThinkingFeedbackAt) >= nextThinkingInterval else {
      return
    }
    lastThinkingFeedbackAt = now
    nextThinkingInterval = Self.randomThinkingInterval()

    let intensity = Self.randomThinkingIntensity()
    thinkingGenerator.prepare()
    thinkingGenerator.impactOccurred(intensity: intensity)
    thinkingGenerator.prepare()
  }

  func responseCompleted() {
    completionGenerator.prepare()
    completionGenerator.notificationOccurred(.success)
    completionGenerator.prepare()
    playLockedCompletionFallbackIfNeeded()
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

  private func playLockedCompletionFallbackIfNeeded() {
    guard UIApplication.shared.applicationState != .active else { return }
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
  }

  private static func randomStreamInterval() -> TimeInterval {
    TimeInterval.random(in: streamIntervalRange)
  }

  private static func randomStreamIntensity() -> CGFloat {
    CGFloat(Double.random(in: streamIntensityRange))
  }

  private static func randomThinkingInterval() -> TimeInterval {
    TimeInterval.random(in: thinkingIntervalRange)
  }

  private static func randomThinkingIntensity() -> CGFloat {
    CGFloat(Double.random(in: thinkingIntensityRange))
  }
}
