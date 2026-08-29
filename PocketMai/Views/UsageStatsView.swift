import SwiftUI

/// Settings → Statistics: lifetime token consumption and generation speed for
/// every provider/model that has been used. A bar chart on top compares average
/// speed across models; tapping a bar names it below the chart.
struct UsageStatsView: View {
  @ObservedObject private var stats = UsageStatsStore.shared
  @State private var selectedID: String?
  @State private var selectedModelIDs: Set<String> = []
  @State private var selectedProviderLabels: Set<String> = []
  @State private var hasInitializedSelections = false
  @State private var confirmingReset = false
  @State private var detailEntry: UsageStatsStore.ModelTotals?
  @State private var deletingProvider: ProviderTotals?

  private static let chartHeight: CGFloat = 120

  /// Fastest first, so the chart reads as a ranking at a glance.
  private var filteredTotals: [UsageStatsStore.ModelTotals] {
    stats.totals.filter {
      selectedProviderLabels.contains($0.providerLabel) && selectedModelIDs.contains($0.id)
    }
  }

  private var chartTotals: [UsageStatsStore.ModelTotals] {
    filteredTotals
      .filter { $0.averageTokensPerSecond != nil }
      .sorted { ($0.averageTokensPerSecond ?? 0) > ($1.averageTokensPerSecond ?? 0) }
  }

  private var listTotals: [UsageStatsStore.ModelTotals] {
    filteredTotals.sorted { $0.lastUsedAt > $1.lastUsedAt }
  }

  private var allModelTotals: [UsageStatsStore.ModelTotals] {
    stats.totals.sorted { $0.lastUsedAt > $1.lastUsedAt }
  }

  private var providerTotals: [ProviderTotals] {
    Dictionary(grouping: stats.totals, by: \.providerLabel)
      .map { providerLabel, entries in
        ProviderTotals(
          providerLabel: providerLabel,
          inputTokens: entries.reduce(0) { $0 + $1.inputTokens },
          userInputTokens: entries.reduce(0) { $0 + ($1.userInputTokens ?? 0) },
          outputTokens: entries.reduce(0) { $0 + $1.outputTokens },
          receivedTextTokens: entries.reduce(0) { $0 + ($1.receivedTextTokens ?? 0) },
          reasoningTokens: entries.reduce(0) { $0 + ($1.reasoningTokens ?? 0) },
          imageInputs: entries.reduce(0) { $0 + ($1.imageInputs ?? 0) },
          estimatedCallCount: entries.reduce(0) { $0 + $1.estimatedCallCount }
        )
      }
      .sorted { $0.providerLabel.localizedCaseInsensitiveCompare($1.providerLabel) == .orderedAscending }
  }

  private var totalInputTokens: Int {
    listTotals.reduce(0) { $0 + $1.inputTokens }
  }

  private var totalUserInputTokens: Int {
    listTotals.reduce(0) { $0 + ($1.userInputTokens ?? 0) }
  }

  private var totalOutputTokens: Int {
    listTotals.reduce(0) { $0 + $1.outputTokens }
  }

  private var totalReceivedTextTokens: Int {
    listTotals.reduce(0) { $0 + ($1.receivedTextTokens ?? 0) }
  }

  private var totalReasoningTokens: Int {
    listTotals.reduce(0) { $0 + ($1.reasoningTokens ?? 0) }
  }

  private var totalImageInputs: Int {
    listTotals.reduce(0) { $0 + ($1.imageInputs ?? 0) }
  }

  private var selectedEntry: UsageStatsStore.ModelTotals? {
    chartTotals.first { $0.id == selectedID } ?? chartTotals.first
  }

  var body: some View {
    List {
      if stats.totals.isEmpty {
        ContentUnavailableView(
          "No Usage Yet",
          systemImage: "chart.bar",
          description: Text("Statistics appear here after the first model response."))
      } else if listTotals.isEmpty {
        ContentUnavailableView(
          "No Statistics Selected",
          systemImage: "line.3.horizontal.decrease.circle",
          description: Text("Select at least one model and provider to show statistics."))
      }
      if !chartTotals.isEmpty {
        Section {
          speedChart
          totalTokensSummary
        } header: {
          Text("Average Output Speed")
        }
      }
      if !allModelTotals.isEmpty {
        Section {
          ForEach(allModelTotals) { entry in
            modelRow(entry)
          }
        } header: {
          Text("Models")
        } footer: {
          if allModelTotals.contains(where: { $0.estimatedCallCount > 0 }) {
            Text("~ marks token counts estimated from text length (~4 characters per token).")
          }
        }
      }
      if !providerTotals.isEmpty {
        Section {
          ForEach(providerTotals) { provider in
            providerRow(provider)
          }
        } header: {
          Text("Providers")
        } footer: {
          Text("Select models and providers to include them in the chart and token totals.")
        }
      }
      if !stats.totals.isEmpty {
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
    .onAppear {
      guard !hasInitializedSelections else { return }
      selectedModelIDs = Set(allModelTotals.map(\.id))
      selectedProviderLabels = Set(providerTotals.map(\.providerLabel))
      hasInitializedSelections = true
    }
    .confirmationDialog(
      "Reset all usage statistics?",
      isPresented: $confirmingReset,
      titleVisibility: .visible
    ) {
      Button("Reset Statistics", role: .destructive) {
        stats.reset()
        selectedID = nil
        selectedModelIDs = []
        selectedProviderLabels = []
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
        selectedModelIDs.remove(entry.id)
        if selectedID == entry.id {
          selectedID = nil
        }
      }
    } message: { entry in
      Text(fullDetailText(for: entry))
    }
    .confirmationDialog(
      deletingProvider.map { "Delete all statistics for \($0.providerLabel)?" } ?? "",
      isPresented: Binding(
        get: { deletingProvider != nil },
        set: { if !$0 { deletingProvider = nil } }
      ),
      titleVisibility: .visible,
      presenting: deletingProvider
    ) { provider in
      Button("Delete Statistics", role: .destructive) {
        let removedIDs = Set(
          stats.totals.filter { $0.providerLabel == provider.providerLabel }.map(\.id))
        stats.remove(providerLabel: provider.providerLabel)
        selectedModelIDs.subtract(removedIDs)
        selectedProviderLabels.remove(provider.providerLabel)
        if let selectedID, removedIDs.contains(selectedID) {
          self.selectedID = nil
        }
      }
    } message: { provider in
      Text("Removes the usage statistics of every model of this provider.")
    }
  }

  private var speedChart: some View {
    let entries = chartTotals
    let maxSpeed = entries.compactMap(\.averageTokensPerSecond).max() ?? 1
    return VStack(spacing: 10) {
      HStack(alignment: .bottom, spacing: 6) {
        ForEach(entries) { entry in
          let isSelected = entry.id == selectedEntry?.id
          speedBar(entry, maxSpeed: maxSpeed, isSelected: isSelected)
            .contentShape(Rectangle())
            .onTapGesture {
              selectedID = entry.id
            }
            .accessibilityLabel(sectionTitle(for: entry))
            .accessibilityValue(speedDescription(for: entry))
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
          Text(speedDescription(for: selected))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.vertical, 6)
  }

  private func speedBar(
    _ entry: UsageStatsStore.ModelTotals,
    maxSpeed: Double,
    isSelected: Bool
  ) -> some View {
    let outputSpeed = outputSpeed(for: entry)
    let barHeight = max(6, Self.chartHeight * outputSpeed / maxSpeed)
    let opacity = isSelected ? 1.0 : 0.35

    return Rectangle()
      .fill(providerColor(for: entry.providerLabel).opacity(opacity))
      .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
      .frame(maxWidth: 48)
      .frame(height: barHeight)
      .frame(maxWidth: .infinity, maxHeight: Self.chartHeight, alignment: .bottom)
  }

  private func outputSpeed(for entry: UsageStatsStore.ModelTotals) -> Double {
    entry.averageTokensPerSecond ?? 0
  }

  private func speedDescription(for entry: UsageStatsStore.ModelTotals) -> String {
    "↓ \(speedText(outputSpeed(for: entry))) output"
  }

  private var totalTokensSummary: some View {
    HStack(spacing: 12) {
      Label("~\(totalUserInputTokens.formatted()) sent", systemImage: "arrow.up")
      Label("~\(totalReceivedTextTokens.formatted()) recv", systemImage: "arrow.down")
      if totalReasoningTokens > 0 {
        Label("\(totalReasoningTokens.formatted()) thinking", systemImage: "brain")
      }
      if totalImageInputs > 0 {
        Label("\(totalImageInputs.formatted()) images", systemImage: "photo")
      }
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .monospacedDigit()
    .frame(maxWidth: .infinity)
  }

  private func modelRow(_ entry: UsageStatsStore.ModelTotals) -> some View {
    let isSelected = selectedModelIDs.contains(entry.id)
    let approx = entry.estimatedCallCount > 0 ? "~" : ""
    return Button {
      if isSelected {
        selectedModelIDs.remove(entry.id)
      } else {
        selectedModelIDs.insert(entry.id)
      }
      if let selectedID,
        !chartTotals.contains(where: { $0.id == selectedID })
      {
        self.selectedID = nil
      }
    } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(sectionTitle(for: entry))
              .font(.subheadline.weight(.medium))
              .foregroundStyle(.primary)
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
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)
      }
    }
    .padding(.vertical, 2)
    .buttonStyle(.plain)
    .listRowBackground(
      isSelected ? providerColor(for: entry.providerLabel).opacity(0.14) : Color.clear)
    .onLongPressGesture {
      detailEntry = entry
    }
    .accessibilityLabel(sectionTitle(for: entry))
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
  }

  private func providerRow(_ provider: ProviderTotals) -> some View {
    let isSelected = selectedProviderLabels.contains(provider.providerLabel)
    let approx = provider.estimatedCallCount > 0 ? "~" : ""
    return Button {
      if isSelected {
        selectedProviderLabels.remove(provider.providerLabel)
      } else {
        selectedProviderLabels.insert(provider.providerLabel)
      }
      if let selectedID,
        !chartTotals.contains(where: { $0.id == selectedID })
      {
        self.selectedID = nil
      }
    } label: {
      HStack(spacing: 10) {
        Circle()
          .fill(providerColor(for: provider.providerLabel))
          .frame(width: 10, height: 10)
        VStack(alignment: .leading, spacing: 3) {
          Text(provider.providerLabel)
            .foregroundStyle(.primary)
          Text(providerDetailText(for: provider, approx: approx))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Spacer()
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)
      }
    }
    .buttonStyle(.plain)
    .onLongPressGesture {
      deletingProvider = provider
    }
    .accessibilityLabel(provider.providerLabel)
    .accessibilityValue("\(isSelected ? "Selected" : "Not selected"), \(providerDetailText(for: provider, approx: approx))")
  }

  private func fullDetailText(for entry: UsageStatsStore.ModelTotals) -> String {
    let approx = entry.estimatedCallCount > 0 ? "~" : ""
    var lines: [String] = []
    if let userInputTokens = entry.userInputTokens, userInputTokens > 0 {
      lines.append("Text sent: ~\(userInputTokens.formatted())")
    }
    if let receivedTextTokens = entry.receivedTextTokens, receivedTextTokens > 0 {
      lines.append("Text received: ~\(receivedTextTokens.formatted())")
    }
    lines.append("Provider prompt tokens: \(approx)\(entry.inputTokens.formatted())")
    lines.append("Provider completion tokens: \(approx)\(entry.outputTokens.formatted())")
    if let reasoningTokens = entry.reasoningTokens, reasoningTokens > 0 {
      lines.append("Thinking tokens: \(reasoningTokens.formatted())")
    }
    if let imageInputs = entry.imageInputs, imageInputs > 0 {
      lines.append("Images sent: \(imageInputs.formatted())")
    }
    if entry.cachedTokens > 0 {
      lines.append("Cached tokens: \(entry.cachedTokens.formatted())")
    }
    lines.append("Requests: \(entry.callCount)")
    if entry.estimatedCallCount > 0 {
      lines.append("Estimated counts: \(entry.estimatedCallCount) req")
    }
    if let average = entry.averageTokensPerSecond {
      lines.append("Average output speed: \(speedText(average))")
    }
    if let last = entry.lastOutputTokensPerSecond {
      lines.append("Last output speed: \(speedText(last))")
    }
    if let promptSpeed = entry.averagePromptTokensPerSecond {
      lines.append("Prompt processing speed: \(speedText(promptSpeed))")
    }
    if let lastFirstToken = entry.lastFirstTokenSeconds {
      lines.append("Last time to first token: \(secondsText(lastFirstToken))")
    }
    if let averageFirstToken = entry.averageFirstTokenSeconds {
      lines.append("Average time to first token: \(secondsText(averageFirstToken))")
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
    var parts: [String] = []
    if let userInputTokens = entry.userInputTokens, userInputTokens > 0 {
      parts.append("~\(tokenText(userInputTokens)) sent")
    }
    if let receivedTextTokens = entry.receivedTextTokens, receivedTextTokens > 0 {
      parts.append("~\(tokenText(receivedTextTokens)) recv")
    }
    if let reasoningTokens = entry.reasoningTokens, reasoningTokens > 0 {
      parts.append("\(tokenText(reasoningTokens)) thinking")
    }
    if let imageInputs = entry.imageInputs, imageInputs > 0 {
      parts.append("\(imageInputs.formatted()) images")
    }
    if entry.cachedTokens > 0 {
      parts.append("\(tokenText(entry.cachedTokens)) cached")
    }
    parts.append("\(entry.callCount) req")
    if let promptSpeed = entry.averagePromptTokensPerSecond {
      parts.append("prompt \(speedText(promptSpeed))")
    }
    if let averageFirstToken = entry.averageFirstTokenSeconds {
      parts.append("first tok \(secondsText(averageFirstToken))")
    }
    return parts.joined(separator: " · ")
  }

  private func providerDetailText(for provider: ProviderTotals, approx: String) -> String {
    var parts: [String] = []
    if provider.userInputTokens > 0 {
      parts.append("~\(tokenText(provider.userInputTokens)) sent")
    }
    if provider.receivedTextTokens > 0 {
      parts.append("~\(tokenText(provider.receivedTextTokens)) recv")
    }
    if provider.reasoningTokens > 0 {
      parts.append("\(tokenText(provider.reasoningTokens)) thinking")
    }
    if provider.imageInputs > 0 {
      parts.append("\(provider.imageInputs.formatted()) images")
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

  private func secondsText(_ seconds: TimeInterval) -> String {
    String(format: seconds >= 10 ? "%.1fs" : "%.2fs", seconds)
  }

  /// A label-derived hue gives every provider a distinct, repeatable chart color.
  private func providerColor(
    for providerLabel: String
  ) -> Color {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in providerLabel.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    let hue = Double(hash % 360) / 360
    return Color(
      hue: hue,
      saturation: 0.68,
      brightness: 0.88)
  }

  private struct ProviderTotals: Identifiable {
    let providerLabel: String
    let inputTokens: Int
    let userInputTokens: Int
    let outputTokens: Int
    let receivedTextTokens: Int
    let reasoningTokens: Int
    let imageInputs: Int
    let estimatedCallCount: Int

    var id: String { providerLabel }
  }
}
