import SwiftUI

struct FilteredModelPicker: View {
  @Binding var selection: String
  @Binding var filter: String
  let models: [String]
  var emptySelectionTitle: String? = nil

  private var sortedModels: [String] {
    models.sorted { lhs, rhs in
      let lhsIsFree = lhs.localizedCaseInsensitiveContains("free")
      let rhsIsFree = rhs.localizedCaseInsensitiveContains("free")
      if lhsIsFree != rhsIsFree { return lhsIsFree }
      return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
  }

  private var filteredModels: [String] {
    let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return sortedModels }
    return sortedModels.filter { $0.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("Model", selection: $selection) {
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

      HStack {
        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        TextField("Model name", text: $filter)
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .textFieldStyle(.plain)
      }
    }
  }
}
