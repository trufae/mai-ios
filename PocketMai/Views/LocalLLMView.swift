import Foundation
import SwiftUI

import HFAPI
import MLXLMCommon
import MLXLMHFAPI
import MLXLMTokenizers

@MainActor
final class LocalLLMViewModel: ObservableObject {
  static let defaultModelId = "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit"

  @Published var selectedModelId = LocalLLMViewModel.defaultModelId
  @Published var customModelId = ""
  @Published var status = "Choose an MLX-ready Hugging Face repo."
  @Published var isLoading = false
  @Published var isCancellingLoad = false
  @Published var isReady = false
  @Published var downloadProgress: Double?
  @Published var cachedModels: [CachedMLXModel] = []

  let presets = [
    "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit",
    "mlx-community/LFM2-350M-MLX",
    "mlx-community/LFM2-2.6B-4bit",
    "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
  ]

  private var container: ModelContainer?
  private var loadedModelId: String?
  private var loadTask: Task<Void, Never>?

  init() {
    refreshCachedModels()
  }

  var activeModelId: String {
    let custom = customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    return custom.isEmpty ? selectedModelId : custom
  }

  var isUsingCustomModelId: Bool {
    !customModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var isActiveModelReady: Bool {
    isReady && loadedModelId == activeModelId
  }

  var loadButtonTitle: String {
    if isLoading {
      return isCancellingLoad ? "Cancelling..." : "Cancel Download"
    }
    return isActiveModelReady ? "Reload Model" : "Download Model"
  }

  var loadButtonSystemImage: String {
    if isLoading {
      return isCancellingLoad ? "hourglass" : "xmark.circle"
    }
    return isActiveModelReady ? "arrow.clockwise" : "arrow.down.circle"
  }

  func toggleModelLoad() {
    if isLoading {
      cancelModelLoad()
      return
    }
    let modelId = activeModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard LocalMLXRepoIDValidator.isValid(modelId) else {
      showFailure(LocalMLXError.invalidModelID(modelId), action: "Model load", modelId: modelId)
      return
    }
    isLoading = true
    isCancellingLoad = false
    isReady = false
    downloadProgress = nil
    status = "Preparing Hugging Face download for \(modelId)..."
    loadTask = Task { [weak self] in
      await self?.loadModel(modelId: modelId)
    }
  }

  func cancelModelLoad() {
    guard isLoading else { return }
    isCancellingLoad = true
    status = "Cancelling model download..."
    loadTask?.cancel()
  }

  private func loadModel(modelId: String) async {
    let previousContainer = container
    let previousLoadedModelId = loadedModelId
    let wasCachedBeforeLoad = LocalMLXModelCache.containsRepository(modelId)
    isLoading = true
    isCancellingLoad = false
    isReady = false
    downloadProgress = nil
    status = "Preparing Hugging Face download for \(modelId)..."
    defer {
      isLoading = false
      isCancellingLoad = false
      downloadProgress = nil
      loadTask = nil
      refreshCachedModels()
    }

    do {
      try Task.checkCancellation()
      let config = ModelConfiguration(id: modelId)
      let progressHandler: @Sendable (Progress) -> Void = { [weak self] progress in
        let total = progress.totalUnitCount
        let fraction = total > 0 ? min(max(progress.fractionCompleted, 0), 1) : nil
        Task { @MainActor in
          guard let self, self.isLoading, self.loadTask?.isCancelled != true else { return }
          self.downloadProgress = fraction
          if let fraction {
            self.status = "Downloading model files... \(Int(fraction * 100))%"
          } else {
            self.status = "Downloading model files..."
          }
        }
      }

      container = try await loadModelContainer(
        from: HubClient.default,
        using: TokenizersLoader(),
        configuration: config,
        progressHandler: progressHandler
      )
      try Task.checkCancellation()
      loadedModelId = modelId
      isReady = true
      status = "Model ready: \(modelId)"
    } catch is CancellationError {
      restorePreviousModel(container: previousContainer, loadedModelId: previousLoadedModelId)
      let cleanupError = removePartialDownloadIfNeeded(
        for: modelId,
        wasCachedBeforeLoad: wasCachedBeforeLoad)
      status = "Model download cancelled.\(cleanupError.map { " \($0)" } ?? "")"
    } catch {
      restorePreviousModel(container: previousContainer, loadedModelId: previousLoadedModelId)
      let cleanupError = removePartialDownloadIfNeeded(
        for: modelId,
        wasCachedBeforeLoad: wasCachedBeforeLoad)
      showFailure(error, action: "Model load", modelId: modelId)
      if let cleanupError {
        status += " \(cleanupError)"
      }
    }
  }

  func refreshCachedModels() {
    cachedModels = LocalMLXModelCache.listModels()
  }

  func deleteCachedModel(_ model: CachedMLXModel) {
    do {
      try LocalMLXModelCache.delete(model)
      if loadedModelId == model.repoID {
        container = nil
        loadedModelId = nil
        isReady = false
      }
      refreshCachedModels()
      status = "Deleted cached model: \(model.repoID)"
    } catch {
      status = "Could not delete \(model.repoID): \(error.localizedDescription)"
    }
  }

  private func showFailure(_ error: Error, action: String, modelId: String) {
    let message = Self.message(for: error, action: action, modelId: modelId)
    isReady = container != nil && loadedModelId == activeModelId
    status = message
  }

  private static func message(for error: Error, action: String, modelId: String) -> String {
    if let localError = error as? LocalMLXError {
      return localError.localizedDescription
    }

    if let factoryError = error as? ModelFactoryError {
      switch factoryError {
      case .unsupportedModelType:
        return "Unsupported model format for \(modelId). Use a Hugging Face repo that is already converted to MLX and supported by mlx-swift-lm."
      case .noModelFactoryAvailable:
        return "MLX LLM support is not available in this build. Check that MLXLLM is linked."
      case .configurationFileError, .configurationDecodingError, .unsupportedProcessorType:
        return "Unsupported MLX model configuration for \(modelId): \(factoryError.localizedDescription)"
      }
    }

    let nsError = error as NSError
    let detail = error.localizedDescription
    let lowercasedDetail = detail.lowercased()

    if nsError.domain == NSURLErrorDomain || error is URLError
      || lowercasedDetail.contains("network")
      || lowercasedDetail.contains("timed out")
      || lowercasedDetail.contains("could not connect")
    {
      return "Download failed for \(modelId): \(detail)"
    }

    if lowercasedDetail.contains("out of memory")
      || lowercasedDetail.contains("memory allocation")
      || lowercasedDetail.contains("failed to allocate")
      || lowercasedDetail.contains("resource exhausted")
    {
      return "Out of memory while using \(modelId). Try a smaller 4-bit MLX model."
    }

    if lowercasedDetail.contains("not found")
      || lowercasedDetail.contains("404")
      || lowercasedDetail.contains("repository")
    {
      return "Invalid model id or unavailable Hugging Face repo: \(modelId). Use an MLX-ready repo id such as org/model-name."
    }

    if lowercasedDetail.contains("safetensor")
      || lowercasedDetail.contains("config.json")
      || lowercasedDetail.contains("unsupported")
    {
      return "Unsupported model format for \(modelId): \(detail)"
    }

    return "\(action) failed for \(modelId): \(detail)"
  }

  private func restorePreviousModel(container: ModelContainer?, loadedModelId: String?) {
    self.container = container
    self.loadedModelId = loadedModelId
    isReady = container != nil && loadedModelId == activeModelId
  }

  private func removePartialDownloadIfNeeded(
    for modelId: String,
    wasCachedBeforeLoad: Bool
  ) -> String? {
    guard !wasCachedBeforeLoad else { return nil }
    do {
      try LocalMLXModelCache.deleteRepository(modelId)
      return nil
    } catch {
      return "Could not remove partial files: \(error.localizedDescription)"
    }
  }
}

struct LocalLLMView: View {
  @StateObject private var vm = LocalLLMViewModel()
  @State private var pendingModelDeletion: CachedMLXModel?

  var body: some View {
    Form {
      Section {
        Picker("Preset", selection: $vm.selectedModelId) {
          ForEach(vm.presets, id: \.self) { id in
            Text(id).tag(id)
          }
        }
        .pickerStyle(.menu)
        .onChange(of: vm.selectedModelId) {
          vm.customModelId = ""
        }
        .disabled(vm.isUsingCustomModelId)

        TextField("Custom Hugging Face MLX repo id", text: $vm.customModelId)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .font(.callout.monospaced())

        if let progress = vm.downloadProgress {
          ProgressView(value: progress)
        }

        Button {
          vm.toggleModelLoad()
        } label: {
          Label(vm.loadButtonTitle, systemImage: vm.loadButtonSystemImage)
        }

        Text(vm.status)
          .font(.caption)
          .foregroundStyle(vm.isActiveModelReady ? Color.secondary : Color.primary)
      } header: {
        Text("Model")
      }

      Section {
        if vm.cachedModels.isEmpty {
          Text("No downloaded models")
            .foregroundStyle(.secondary)
        } else {
          ForEach(vm.cachedModels) { model in
            cachedModelRow(model)
          }
        }

        Button {
          vm.refreshCachedModels()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(vm.isLoading)
      } header: {
        Text("Downloaded Models")
      }
    }
    .navigationTitle("Local MLX LLM")
    .alert(item: $pendingModelDeletion) { model in
      Alert(
        title: Text("Delete Downloaded Model?"),
        message: Text(
          "\(model.repoID) will be removed from the local Hugging Face cache and must be downloaded again before use."
        ),
        primaryButton: .destructive(Text("Delete")) {
          vm.deleteCachedModel(model)
        },
        secondaryButton: .cancel()
      )
    }
  }

  private func cachedModelRow(_ model: CachedMLXModel) -> some View {
    let isCurrentModel = vm.isActiveModelReady && model.repoID == vm.activeModelId

    return HStack(spacing: 12) {
      Image(systemName: isCurrentModel ? "checkmark.circle.fill" : "shippingbox")
        .foregroundStyle(isCurrentModel ? Color.green : Color.secondary)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 3) {
        Text(model.repoID)
          .font(.body)
          .lineLimit(2)
        Text(model.detailText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) {
        pendingModelDeletion = model
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .disabled(vm.isLoading)
    }
  }
}
