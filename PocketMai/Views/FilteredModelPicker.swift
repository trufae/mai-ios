import SwiftUI

struct FilteredModelPicker: View {
  @Binding var selection: String
  @Binding var filter: String
  let models: [String]
  var title: String = "Model"
  var emptySelectionTitle: String? = nil
  @State private var sortedModels: [String] = []
  @State private var sortingTask: Task<Void, Never>?

  private var filteredModels: [String] {
    let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return sortedModels }
    return sortedModels.filter { $0.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    Group {
      Picker(title, selection: $selection) {
        if !selection.isEmpty && !filteredModels.contains(selection) {
          Text(selection).tag(selection)
        }
        if selection.isEmpty, let emptySelectionTitle {
          Text(emptySelectionTitle).tag("")
        }
        ForEach(filteredModels, id: \.self) { model in
          Text(model).tag(model)
        }
        if filteredModels.isEmpty && selection.isEmpty {
          Text("No matching models").tag("__no_matching_model__")
            .disabled(true)
        }
      }
      .pickerStyle(.menu)

      LabeledContent("Filter") {
        TextField("Model name", text: $filter)
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .textFieldStyle(.plain)
      }
    }
    .onAppear {
      updateSortedModels(models)
    }
    .onChange(of: models) { _, models in
      updateSortedModels(models)
    }
    .onDisappear {
      sortingTask?.cancel()
      sortingTask = nil
    }
  }

  private func updateSortedModels(_ models: [String]) {
    sortingTask?.cancel()
    sortedModels = models
    sortingTask = Task.detached(priority: .utility) {
      let sorted = Self.sorted(models)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard !Task.isCancelled else { return }
        sortedModels = sorted
      }
    }
  }

  nonisolated private static func sorted(_ models: [String]) -> [String] {
    models.sorted { lhs, rhs in
      let lhsIsFree = lhs.localizedCaseInsensitiveContains("free")
      let rhsIsFree = rhs.localizedCaseInsensitiveContains("free")
      if lhsIsFree != rhsIsFree { return lhsIsFree }
      return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
  }
}
