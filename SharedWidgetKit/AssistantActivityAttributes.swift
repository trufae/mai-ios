import ActivityKit
import Foundation

/// One assistant turn tracked by the Live Activity. The app publishes these and
/// the widget extension renders them on the Lock Screen and in the Dynamic
/// Island, so the type lives in the target both of them compile.
struct AssistantActivityTask: Codable, Hashable, Identifiable, Sendable {
  enum Phase: String, Codable, Hashable, Sendable {
    case loadingModel
    case thinking
    case streaming
    case runningTool
    case awaitingApproval
    case paused
    case completed
    case failed
    case stopped

    var isTerminal: Bool {
      switch self {
      case .completed, .failed, .stopped: true
      case .loadingModel, .thinking, .streaming, .runningTool, .awaitingApproval, .paused: false
      }
    }

    /// Phases where the turn cannot make progress until the user does something.
    var needsAttention: Bool {
      self == .awaitingApproval || self == .paused
    }

    var systemImage: String {
      switch self {
      case .loadingModel: "arrow.down.circle"
      case .thinking: "brain"
      case .streaming: "text.bubble"
      case .runningTool: "wrench.and.screwdriver"
      case .awaitingApproval: "hand.raised"
      case .paused: "pause.circle"
      case .completed: "checkmark.circle.fill"
      case .failed: "exclamationmark.triangle.fill"
      case .stopped: "stop.circle"
      }
    }

    var label: String {
      switch self {
      case .loadingModel: "Loading model"
      case .thinking: "Thinking"
      case .streaming: "Replying"
      case .runningTool: "Running tool"
      case .awaitingApproval: "Needs approval"
      case .paused: "Paused"
      case .completed: "Done"
      case .failed: "Failed"
      case .stopped: "Stopped"
      }
    }

    /// Fits the compact Dynamic Island trailing slot.
    var shortLabel: String {
      switch self {
      case .loadingModel: "Loading"
      case .thinking: "Thinking"
      case .streaming: "Replying"
      case .runningTool: "Tool"
      case .awaitingApproval: "Approve"
      case .paused: "Paused"
      case .completed: "Done"
      case .failed: "Failed"
      case .stopped: "Stopped"
      }
    }
  }

  static let titleLimit = 60
  static let detailLimit = 140

  var id: UUID
  var title: String
  var phase: Phase
  /// Tool name, the tail of the streamed reply, or the final summary depending on `phase`.
  var detail: String
  var startedAt: Date
  var finishedAt: Date?

  init(
    id: UUID,
    title: String,
    phase: Phase,
    detail: String = "",
    startedAt: Date = Date(),
    finishedAt: Date? = nil
  ) {
    self.id = id
    self.title = Self.leadingSummary(title, limit: Self.titleLimit)
    self.phase = phase
    self.detail = Self.leadingSummary(detail, limit: Self.detailLimit)
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }

  static func collapsedWhitespace(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// The beginning of `text` on a single line, cut to `limit` characters.
  static func leadingSummary(_ text: String, limit: Int = detailLimit) -> String {
    let collapsed = collapsedWhitespace(text)
    guard collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// The end of `text` on a single line, cut to `limit` characters. Used while a
  /// reply streams so the card shows the words being written right now.
  static func trailingSummary(_ text: String, limit: Int = detailLimit) -> String {
    let collapsed = collapsedWhitespace(text)
    guard collapsed.count > limit else { return collapsed }
    return "…" + String(collapsed.suffix(limit)).trimmingCharacters(in: .whitespaces)
  }
}

struct AssistantActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable, Sendable {
    var tasks: [AssistantActivityTask]
    var updatedAt: Date

    var activeTasks: [AssistantActivityTask] {
      tasks.filter { !$0.phase.isTerminal }
    }

    var isFinished: Bool {
      !tasks.isEmpty && tasks.allSatisfy { $0.phase.isTerminal }
    }

    /// The task the compact presentations describe: anything blocked on the
    /// user wins, then the oldest running turn, then the last finished one.
    var primaryTask: AssistantActivityTask? {
      tasks.first { $0.phase.needsAttention } ?? activeTasks.first ?? tasks.last
    }
  }

  var startedAt: Date
}
