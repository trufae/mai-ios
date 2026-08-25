import SwiftUI
import WidgetKit

struct VoiceWidgetEntry: TimelineEntry {
  let date: Date
}

struct VoiceWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> VoiceWidgetEntry {
    VoiceWidgetEntry(date: Date())
  }

  func getSnapshot(in context: Context, completion: @escaping (VoiceWidgetEntry) -> Void) {
    completion(VoiceWidgetEntry(date: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceWidgetEntry>) -> Void) {
    completion(Timeline(entries: [VoiceWidgetEntry(date: Date())], policy: .never))
  }
}

struct VoiceWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "PocketMaiVoiceWidget", provider: VoiceWidgetProvider()) { _ in
      VoiceWidgetView()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(PocketMaiDeepLink.url(for: .voice))
    }
    .configurationDisplayName("Voice Mode")
    .description("Tap to start a voice conversation.")
    .supportedFamilies([
      .systemSmall,
      .accessoryCircular,
    ])
  }
}

private struct VoiceWidgetView: View {
  @Environment(\.widgetFamily) private var family

  var body: some View {
    switch family {
    case .accessoryCircular:
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: "waveform")
          .font(.title2)
          .symbolRenderingMode(.hierarchical)
      }
    default:
      VStack(spacing: 10) {
        Image(systemName: "waveform")
          .font(.system(size: 44, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.tint)
        Text("Voice")
          .font(.headline)
        Text("Talk to PocketMai")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
