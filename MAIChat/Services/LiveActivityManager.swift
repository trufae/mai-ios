import ActivityKit
import Foundation

final class LiveActivityManager: @unchecked Sendable {
  private var activity: Activity<ChatActivityAttributes>?

  func start(conversation: Conversation) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    let attributes = ChatActivityAttributes(
      conversationID: conversation.id.uuidString,
      title: conversation.displayTitle
    )
    let state = ChatActivityAttributes.ContentState(
      status: "Thinking",
      preview: conversation.messages.last?.text ?? "",
      tokenCount: 0
    )
    do {
      activity = try Activity.request(
        attributes: attributes,
        content: ActivityContent(state: state, staleDate: nil),
        pushType: nil,
        style: .standard
      )
    } catch {
      activity = nil
    }
  }

  func update(status: String, preview: String, tokenCount: Int) async {
    let state = ChatActivityAttributes.ContentState(
      status: status, preview: preview, tokenCount: tokenCount)
    await activity?.update(ActivityContent(state: state, staleDate: nil))
  }

  func end(finalText: String) async {
    let state = ChatActivityAttributes.ContentState(
      status: "Complete",
      preview: finalText,
      tokenCount: finalText.split(whereSeparator: \.isWhitespace).count
    )
    await activity?.end(
      ActivityContent(state: state, staleDate: nil),
      dismissalPolicy: .after(Date().addingTimeInterval(20)))
    activity = nil
  }
}
