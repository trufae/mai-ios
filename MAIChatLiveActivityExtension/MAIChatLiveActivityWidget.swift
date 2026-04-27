import ActivityKit
import SwiftUI
import WidgetKit

struct MAIChatLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ChatActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Image(systemName: "sparkles")
          Text(context.attributes.title)
            .font(.headline)
            .lineLimit(1)
          Spacer()
          Text(context.state.status)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text(context.state.preview)
          .font(.subheadline)
          .lineLimit(2)
        Text("\(context.state.tokenCount) words")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding()
      .activityBackgroundTint(.black.opacity(0.08))
      .activitySystemActionForegroundColor(.accentColor)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(context.state.status, systemImage: "sparkles")
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text("\(context.state.tokenCount) words")
            .font(.caption)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.preview)
            .lineLimit(2)
        }
      } compactLeading: {
        Image(systemName: "sparkles")
      } compactTrailing: {
        Text("\(context.state.tokenCount)")
      } minimal: {
        Image(systemName: "bubble.left")
      }
    }
  }
}

@main
struct MAIChatLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    MAIChatLiveActivityWidget()
  }
}
