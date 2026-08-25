import SwiftUI
import WidgetKit

struct PromptWidgetEntry: TimelineEntry {
  let date: Date
  let providerLabel: String
  let modelLabel: String
}

struct PromptWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> PromptWidgetEntry {
    PromptWidgetEntry(date: Date(), providerLabel: "PocketMai", modelLabel: "")
  }

  func getSnapshot(in context: Context, completion: @escaping (PromptWidgetEntry) -> Void) {
    completion(currentEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<PromptWidgetEntry>) -> Void)
  {
    // The app pushes reloads via WidgetCenter whenever the selection changes, so
    // a single static entry is enough — no timed refreshes needed.
    completion(Timeline(entries: [currentEntry()], policy: .never))
  }

  private func currentEntry() -> PromptWidgetEntry {
    let provider = SharedAppState.providerLabel
    return PromptWidgetEntry(
      date: Date(),
      providerLabel: provider.isEmpty ? "PocketMai" : provider,
      modelLabel: SharedAppState.modelLabel)
  }
}

struct PromptWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "PocketMaiPromptWidget", provider: PromptWidgetProvider()) { entry in
      PromptWidgetView(entry: entry)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(PocketMaiDeepLink.url(for: .newPrompt(text: nil)))
    }
    .configurationDisplayName("New Prompt")
    .description("Tap to start a new PocketMai chat.")
    .supportedFamilies([
      .systemSmall,
      .systemMedium,
      .accessoryRectangular,
      .accessoryInline,
    ])
  }
}

private struct PromptWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: PromptWidgetEntry

  var body: some View {
    switch family {
    case .accessoryInline:
      Label("New PocketMai prompt", systemImage: "square.and.pencil")
    case .accessoryRectangular:
      accessoryRectangular
    case .systemMedium:
      homeCard(compact: false)
    default:
      homeCard(compact: true)
    }
  }

  private var accessoryRectangular: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label("New Prompt", systemImage: "square.and.pencil")
        .font(.headline)
      if !entry.modelLabel.isEmpty {
        Text(entry.modelLabel)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      } else {
        Text(entry.providerLabel)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  private func homeCard(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 10) {
      HStack(spacing: 6) {
        Image(systemName: "sparkles")
          .foregroundStyle(.tint)
        Text("PocketMai")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }

      // A "search field" look; widgets can't hold a live text field, so tapping
      // opens the app's composer instead.
      HStack(spacing: 6) {
        Image(systemName: "square.and.pencil")
          .foregroundStyle(.secondary)
        Text("Ask anything…")
          .font(compact ? .footnote : .subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, compact ? 8 : 10)
      .background(.quaternary, in: Capsule())

      Spacer(minLength: 0)

      providerModelFooter
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder private var providerModelFooter: some View {
    let model = entry.modelLabel
    HStack(spacing: 4) {
      Image(systemName: "cpu")
        .imageScale(.small)
        .foregroundStyle(.secondary)
      Text(model.isEmpty ? entry.providerLabel : "\(entry.providerLabel) · \(model)")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}
