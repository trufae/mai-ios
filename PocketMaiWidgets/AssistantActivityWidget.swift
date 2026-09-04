import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner and Dynamic Island presentations for running assistant
/// turns. The app owns the activity lifecycle; this file only renders the
/// content state it publishes.
struct AssistantActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: AssistantActivityAttributes.self) { context in
      AssistantActivityLockScreenView(state: context.state)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .widgetURL(AssistantActivityLink.url(for: context.state))
    } dynamicIsland: { context in
      let state = context.state
      let phase = state.primaryTask?.phase ?? .thinking
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          AssistantActivityPhaseIcon(phase: phase, size: 24)
            .padding(.leading, 6)
            .padding(.top, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          AssistantActivityElapsedText(task: state.primaryTask, state: state)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.trailing, 6)
            .padding(.top, 8)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text(state.primaryTask?.title ?? "PocketMai")
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
            Text(AssistantActivityText.statusLine(for: state))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          AssistantActivityDetailStack(state: state, secondaryRowLimit: 2)
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
      } compactLeading: {
        AssistantActivityPhaseIcon(phase: phase, size: 14)
          .padding(.leading, 2)
      } compactTrailing: {
        Text(AssistantActivityText.compactStatus(for: state))
          .font(.caption2.weight(.semibold))
          .foregroundStyle(AssistantActivityStyle.tint(for: phase))
          .lineLimit(1)
          .padding(.trailing, 2)
      } minimal: {
        AssistantActivityPhaseIcon(phase: phase, size: 12)
      }
      .widgetURL(AssistantActivityLink.url(for: state))
      .keylineTint(AssistantActivityStyle.tint(for: phase))
    }
  }
}

// MARK: - Lock Screen

private struct AssistantActivityLockScreenView: View {
  let state: AssistantActivityAttributes.ContentState

  var body: some View {
    let primary = state.primaryTask
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 10) {
        AssistantActivityPhaseIcon(phase: primary?.phase ?? .thinking, size: 22)
        VStack(alignment: .leading, spacing: 1) {
          Text(primary?.title ?? "PocketMai")
            .font(.headline)
            .lineLimit(1)
          Text(AssistantActivityText.statusLine(for: state))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        AssistantActivityElapsedText(task: primary, state: state)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      AssistantActivityDetailStack(state: state, secondaryRowLimit: 2)
    }
  }
}

// MARK: - Shared pieces

/// The primary task's detail line followed by one compact row per other task.
private struct AssistantActivityDetailStack: View {
  let state: AssistantActivityAttributes.ContentState
  let secondaryRowLimit: Int

  var body: some View {
    let primary = state.primaryTask
    let others = state.tasks.filter { $0.id != primary?.id }
    VStack(alignment: .leading, spacing: 6) {
      if let primary, AssistantActivityText.showsDetail(for: primary) {
        Text(primary.detail)
          .font(.subheadline)
          .foregroundStyle(.primary.opacity(0.85))
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !others.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(others.prefix(secondaryRowLimit)) { task in
            Link(destination: PocketMaiDeepLink.url(for: .openConversation(id: task.id))) {
              HStack(spacing: 6) {
                AssistantActivityPhaseIcon(phase: task.phase, size: 12)
                Text(task.title)
                  .font(.caption)
                  .lineLimit(1)
                Spacer(minLength: 4)
                Text(task.phase.label)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
          if others.count > secondaryRowLimit {
            Text("+\(others.count - secondaryRowLimit) more")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

private struct AssistantActivityPhaseIcon: View {
  let phase: AssistantActivityTask.Phase
  let size: CGFloat

  var body: some View {
    Image(systemName: phase.systemImage)
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(AssistantActivityStyle.tint(for: phase))
      .symbolEffect(
        .pulse,
        options: .repeating,
        isActive: !phase.isTerminal && !phase.needsAttention
      )
      .frame(width: size + 6, height: size + 6)
  }
}

/// A live timer while the turn runs and the final duration once it ends.
private struct AssistantActivityElapsedText: View {
  let task: AssistantActivityTask?
  let state: AssistantActivityAttributes.ContentState

  var body: some View {
    if let task {
      if task.phase.isTerminal {
        Text(
          AssistantActivityText.duration(
            from: task.startedAt, to: task.finishedAt ?? state.updatedAt))
      } else {
        Text(
          timerInterval: task.startedAt...task.startedAt.addingTimeInterval(4 * 60 * 60),
          countsDown: false
        )
      }
    }
  }
}

private enum AssistantActivityStyle {
  static func tint(for phase: AssistantActivityTask.Phase) -> Color {
    switch phase {
    case .completed: .green
    case .failed: .red
    case .awaitingApproval, .paused: .orange
    case .stopped: .secondary
    case .loadingModel, .thinking, .streaming, .runningTool: .accentColor
    }
  }
}

private enum AssistantActivityLink {
  static func url(for state: AssistantActivityAttributes.ContentState) -> URL {
    if let primary = state.primaryTask {
      return PocketMaiDeepLink.url(for: .openConversation(id: primary.id))
    }
    return PocketMaiDeepLink.url(for: .newPrompt(text: nil))
  }
}

private enum AssistantActivityText {
  static func compactStatus(for state: AssistantActivityAttributes.ContentState) -> String {
    if let attention = state.tasks.first(where: { $0.phase.needsAttention }) {
      return attention.phase.shortLabel
    }
    let active = state.activeTasks
    if active.count > 1 {
      return "\(active.count) chats"
    }
    return state.primaryTask?.phase.shortLabel ?? "Idle"
  }

  static func statusLine(for state: AssistantActivityAttributes.ContentState) -> String {
    guard let primary = state.primaryTask else { return "Idle" }
    var line = primary.phase.label
    switch primary.phase {
    case .runningTool, .awaitingApproval:
      if !primary.detail.isEmpty {
        line += " · \(primary.detail)"
      }
    default:
      break
    }
    let running = state.activeTasks.count
    if running > 1 {
      line += " · \(running) running"
    }
    return line
  }

  /// Tool phases already put their detail in the status line.
  static func showsDetail(for task: AssistantActivityTask) -> Bool {
    switch task.phase {
    case .runningTool, .awaitingApproval: false
    default: !task.detail.isEmpty
    }
  }

  static func duration(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
    let minutes = seconds / 60
    if minutes >= 60 {
      return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds % 60)
    }
    return String(format: "%d:%02d", minutes, seconds % 60)
  }
}
