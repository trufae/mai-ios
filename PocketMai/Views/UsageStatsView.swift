import SwiftUI

/// Settings → Statistics: lifetime token consumption and generation speed for
/// every provider/model that has been used. A bar chart on top compares average
/// speed across models; tapping a bar names it below the chart.
struct UsageStatsView: View {
  @ObservedObject private var stats = UsageStatsStore.shared
  @State private var selectedID: String?
  @State private var confirmingReset = false
  @State private var detailEntry: UsageStatsStore.ModelTotals?

  private static let chartHeight: CGFloat = 120

  /// Fastest first, so the chart reads as a ranking at a glance.
  private var chartTotals: [UsageStatsStore.ModelTotals] {
    stats.totals
      .filter { $0.averageTokensPerSecond != nil }
      .sorted { ($0.averageTokensPerSecond ?? 0) > ($1.averageTokensPerSecond ?? 0) }
  }

  private var listTotals: [UsageStatsStore.ModelTotals] {
    stats.totals.sorted { $0.lastUsedAt > $1.lastUsedAt }
  }

  private var selectedEntry: UsageStatsStore.ModelTotals? {
    chartTotals.first { $0.id == selectedID } ?? chartTotals.first
  }

  var body: some View {
    List {
      if listTotals.isEmpty {
        ContentUnavailableView(
          "No Usage Yet",
          systemImage: "chart.bar",
          description: Text("Statistics appear here after the first model response."))
      }
      if chartTotals.count > 1 {
        Section {
          speedChart
        } header: {
          Text("Average Speed")
        }
      }
      if !listTotals.isEmpty {
        Section {
          ForEach(listTotals) { entry in
            modelRow(entry)
          }
        } header: {
          Text("Models")
        } footer: {
          if listTotals.contains(where: { $0.estimatedCallCount > 0 }) {
            Text("~ marks token counts estimated from text length (~4 characters per token).")
          }
        }
        Section {
          Button(role: .destructive) {
            confirmingReset = true
          } label: {
            Label("Reset Statistics", systemImage: "trash")
          }
        }
      }
    }
    .navigationTitle("Statistics")
    .confirmationDialog(
      "Reset all usage statistics?",
      isPresented: $confirmingReset,
      titleVisibility: .visible
    ) {
      Button("Reset Statistics", role: .destructive) {
        stats.reset()
        selectedID = nil
      }
    }
    .confirmationDialog(
      detailEntry.map(sectionTitle(for:)) ?? "",
      isPresented: Binding(
        get: { detailEntry != nil },
        set: { if !$0 { detailEntry = nil } }
      ),
      titleVisibility: .visible,
      presenting: detailEntry
    ) { entry in
      Button("Delete Statistics", role: .destructive) {
        stats.remove(id: entry.id)
        if selectedID == entry.id {
          selectedID = nil
        }
      }
    } message: { entry in
      Text(fullDetailText(for: entry))
    }
  }

  private var speedChart: some View {
    let entries = chartTotals
    let maxSpeed = entries.compactMap(\.averageTokensPerSecond).max() ?? 1
    return VStack(spacing: 10) {
      HStack(alignment: .bottom, spacing: 6) {
        ForEach(entries) { entry in
          let speed = entry.averageTokensPerSecond ?? 0
          let isSelected = entry.id == selectedEntry?.id
          UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
            .fill(Color.accentColor.opacity(isSelected ? 1 : 0.35))
            .frame(maxWidth: 48)
            .frame(height: max(6, Self.chartHeight * speed / maxSpeed))
            .frame(maxWidth: .infinity, maxHeight: Self.chartHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture {
              selectedID = entry.id
            }
            .accessibilityLabel(sectionTitle(for: entry))
            .accessibilityValue(speedText(speed))
        }
      }
      .animation(.snappy(duration: 0.2), value: selectedID)
      if let selected = selectedEntry {
        HStack(spacing: 6) {
          Text(sectionTitle(for: selected))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(speedText(selected.averageTokensPerSecond ?? 0))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.vertical, 6)
  }

  private func modelRow(_ entry: UsageStatsStore.ModelTotals) -> some View {
    let approx = entry.estimatedCallCount > 0 ? "~" : ""
    return VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(sectionTitle(for: entry))
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        if let average = entry.averageTokensPerSecond {
          Text(speedText(average))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
      Text(detailText(for: entry, approx: approx))
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onTapGesture {
      if chartTotals.contains(where: { $0.id == entry.id }) {
        selectedID = entry.id
      }
    }
    .onLongPressGesture {
      detailEntry = entry
    }
  }

  private func fullDetailText(for entry: UsageStatsStore.ModelTotals) -> String {
    let approx = entry.estimatedCallCount > 0 ? "~" : ""
    var lines = [
      "Input tokens: \(approx)\(entry.inputTokens.formatted())",
      "Output tokens: \(approx)\(entry.outputTokens.formatted())",
    ]
    if entry.cachedTokens > 0 {
      lines.append("Cached tokens: \(entry.cachedTokens.formatted())")
    }
    lines.append("Requests: \(entry.callCount)")
    if entry.estimatedCallCount > 0 {
      lines.append("Estimated counts: \(entry.estimatedCallCount) req")
    }
    if let average = entry.averageTokensPerSecond {
      lines.append("Average speed: \(speedText(average))")
    }
    if let last = entry.lastTokensPerSecond {
      lines.append("Last speed: \(speedText(last))")
    }
    if let promptSpeed = entry.averagePromptTokensPerSecond {
      lines.append("Prompt speed: \(speedText(promptSpeed))")
    }
    if entry.generationSeconds > 0 {
      lines.append(
        "Generation time: \(Duration.seconds(entry.generationSeconds).formatted(.units(allowed: [.hours, .minutes, .seconds])))"
      )
    }
    if entry.lastUsedAt > .distantPast {
      lines.append(
        "Last used: \(entry.lastUsedAt.formatted(date: .abbreviated, time: .shortened))")
    }
    return lines.joined(separator: "\n")
  }

  private func detailText(for entry: UsageStatsStore.ModelTotals, approx: String) -> String {
    var parts = [
      "\(approx)\(tokenText(entry.inputTokens)) in",
      "\(approx)\(tokenText(entry.outputTokens)) out",
    ]
    if entry.cachedTokens > 0 {
      parts.append("\(tokenText(entry.cachedTokens)) cached")
    }
    parts.append("\(entry.callCount) req")
    if let promptSpeed = entry.averagePromptTokensPerSecond {
      parts.append("prompt \(speedText(promptSpeed))")
    }
    return parts.joined(separator: " · ")
  }

  private func sectionTitle(for entry: UsageStatsStore.ModelTotals) -> String {
    entry.modelID.isEmpty || entry.modelID == entry.providerLabel
      ? entry.providerLabel
      : "\(entry.providerLabel) — \(entry.modelID)"
  }

  private func tokenText(_ count: Int) -> String {
    count.formatted(.number.notation(.compactName))
  }

  private func speedText(_ tokensPerSecond: Double) -> String {
    String(format: "%.1f tok/s", tokensPerSecond)
  }
}
