import Foundation
import SwiftUI

import HFAPI
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMHFAPI
import MLXLMTokenizers

@MainActor
final class LocalLLMViewModel: ObservableObject {
  static let defaultModelId = "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit"
  private static let benchmarkPrompt = "Write one short sentence about local AI."

  @Published var selectedModelId = LocalLLMViewModel.defaultModelId
  @Published var customModelId = ""
  @Published var status = "Choose an MLX-ready Hugging Face repo."
  @Published var isLoading = false
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

  init() {
    refreshCachedModels()
  }

  var activeModelId: String {
    let custom = customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    return custom.isEmpty ? selectedModelId : custom
  }

  var isActiveModelReady: Bool {
    isReady && loadedModelId == activeModelId
  }

  var canTest: Bool {
    isActiveModelReady && !isLoading
  }

  func loadModel() async {
    let modelId = activeModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard RepoIDValidator.isValid(modelId) else {
      showFailure(LocalLLMError.invalidModelID(modelId), action: "Model load", modelId: modelId)
      return
    }

    isLoading = true
    isReady = false
    downloadProgress = nil
    status = "Preparing Hugging Face download for \(modelId)..."
    defer {
      isLoading = false
      downloadProgress = nil
      refreshCachedModels()
    }

    do {
      let config = ModelConfiguration(id: modelId)
      let progressHandler: @Sendable (Progress) -> Void = { [weak self] progress in
        let total = progress.totalUnitCount
        let fraction = total > 0 ? min(max(progress.fractionCompleted, 0), 1) : nil
        Task { @MainActor in
          guard let self else { return }
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
      loadedModelId = modelId
      isReady = true
      status = "Model ready: \(modelId)"
    } catch is CancellationError {
      status = "Model load cancelled."
    } catch {
      container = nil
      loadedModelId = nil
      showFailure(error, action: "Model load", modelId: modelId)
    }
  }

  func runTest() async {
    guard let container, isActiveModelReady else {
      status = "Load the active model before running the test."
      return
    }

    isLoading = true
    status = "Running MLX benchmark..."
    defer { isLoading = false }

    do {
      let input = try await container.prepare(input: UserInput(prompt: Self.benchmarkPrompt))
      let stream = try await container.generate(
        input: input,
        parameters: GenerateParameters(maxTokens: 128, temperature: 0.2)
      )

      var tokenCount = 0
      var tokensPerSecond: Double?
      for await generation in stream {
        try Task.checkCancellation()
        switch generation {
        case .chunk:
          break
        case .info(let info):
          tokenCount = info.generationTokenCount
          tokensPerSecond = info.tokensPerSecond
        case .toolCall:
          break
        }
      }

      if let tokensPerSecond {
        let formattedTPS = tokensPerSecond.formatted(.number.precision(.fractionLength(1)))
        let modelId = loadedModelId ?? activeModelId
        status = "Benchmark complete for \(modelId): \(tokenCount) tokens at \(formattedTPS) TPS."
      } else {
        status = "Benchmark complete, but MLX did not report TPS."
      }
    } catch is CancellationError {
      status = "Benchmark cancelled."
    } catch {
      showFailure(error, action: "Benchmark", modelId: loadedModelId ?? activeModelId)
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
    isReady = container != nil && loadedModelId != nil
    status = message
  }

  private static func message(for error: Error, action: String, modelId: String) -> String {
    if let localError = error as? LocalLLMError {
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
}

struct CachedMLXModel: Identifiable, Equatable {
  let repoID: String
  let cacheDirectoryName: String
  let directoryURL: URL
  let sizeInBytes: Int64
  let modifiedAt: Date?

  var id: String { directoryURL.path }

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
  }

  var detailText: String {
    guard let modifiedAt else { return sizeText }
    return "\(sizeText) - \(modifiedAt.formatted(date: .abbreviated, time: .shortened))"
  }
}

private enum LocalMLXModelCache {
  private static let modelDirectoryPrefix = "models--"

  static func listModels() -> [CachedMLXModel] {
    let root = HubClient.default.cache.cacheDirectory
    let fileManager = FileManager.default
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return urls.compactMap { url in
      let directoryName = url.lastPathComponent
      guard let repoID = repoID(fromCacheDirectoryName: directoryName) else { return nil }
      guard
        let resourceValues = try? url.resourceValues(forKeys: [
          .isDirectoryKey, .contentModificationDateKey,
        ]),
        resourceValues.isDirectory == true
      else {
        return nil
      }

      return CachedMLXModel(
        repoID: repoID,
        cacheDirectoryName: directoryName,
        directoryURL: url,
        sizeInBytes: directorySize(url),
        modifiedAt: resourceValues.contentModificationDate
      )
    }
    .sorted {
      $0.repoID.localizedCaseInsensitiveCompare($1.repoID) == .orderedAscending
    }
  }

  static func delete(_ model: CachedMLXModel) throws {
    let root = HubClient.default.cache.cacheDirectory
    let cacheEntries = [
      root.appendingPathComponent(model.cacheDirectoryName),
      root.appendingPathComponent(".metadata").appendingPathComponent(model.cacheDirectoryName),
      root.appendingPathComponent(".locks").appendingPathComponent(model.cacheDirectoryName),
    ]

    for url in cacheEntries {
      try removeItemIfPresent(url, under: root)
    }
  }

  private static func repoID(fromCacheDirectoryName name: String) -> String? {
    guard name.hasPrefix(modelDirectoryPrefix) else { return nil }
    let rawRepoID = String(name.dropFirst(modelDirectoryPrefix.count))
    let parts = rawRepoID.components(separatedBy: "--")
    guard parts.count == 2 else { return nil }

    let repoID = "\(parts[0])/\(parts[1])"
    return RepoIDValidator.isValid(repoID) ? repoID : nil
  }

  private static func directorySize(_ url: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .fileAllocatedSizeKey,
      .totalFileAllocatedSizeKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
      if values.isRegularFile == true || values.isSymbolicLink == true {
        total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
      }
    }
    return total
  }

  private static func removeItemIfPresent(_ url: URL, under root: URL) throws {
    let rootPath = root.standardizedFileURL.path
    let itemURL = url.standardizedFileURL
    guard itemURL.path.hasPrefix(rootPath + "/") else {
      throw LocalMLXModelCacheError.invalidCachePath
    }
    guard FileManager.default.fileExists(atPath: itemURL.path) else { return }
    try FileManager.default.removeItem(at: itemURL)
  }
}

private enum LocalMLXModelCacheError: LocalizedError {
  case invalidCachePath

  var errorDescription: String? {
    switch self {
    case .invalidCachePath:
      return "Refusing to delete a path outside the Hugging Face cache."
    }
  }
}

private enum LocalLLMError: LocalizedError {
  case invalidModelID(String)

  var errorDescription: String? {
    switch self {
    case .invalidModelID(let id):
      if id.isEmpty {
        return "Enter a Hugging Face repo id in the form org/model-name."
      }
      return "Invalid model id: \(id). Use a Hugging Face repo id in the form org/model-name, not a URL or local path."
    }
  }
}

private enum RepoIDValidator {
  private static let allowed = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
  )

  static func isValid(_ repoID: String) -> Bool {
    let parts = repoID.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    return parts.allSatisfy { part in
      isValidRepoComponent(String(part))
    }
  }

  private static func isValidRepoComponent(_ component: String) -> Bool {
    guard !component.isEmpty, component.count <= 96 else { return false }
    guard component.rangeOfCharacter(from: allowed.inverted) == nil else { return false }
    guard !component.hasPrefix("."), !component.hasPrefix("-") else { return false }
    guard !component.hasSuffix("."), !component.hasSuffix("-") else { return false }
    guard !component.contains(".."), !component.contains("--") else { return false }
    return true
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

        TextField("Custom Hugging Face MLX repo id", text: $vm.customModelId)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .font(.callout.monospaced())

        LabeledContent("Active", value: vm.activeModelId)
          .font(.caption)

        if let progress = vm.downloadProgress {
          ProgressView(value: progress)
        }

        Button {
          Task { await vm.loadModel() }
        } label: {
          Label(
            vm.isActiveModelReady ? "Reload Model" : "Download / Load Model",
            systemImage: vm.isActiveModelReady ? "arrow.clockwise" : "arrow.down.circle"
          )
        }
        .disabled(vm.isLoading)

        Text(vm.status)
          .font(.caption)
          .foregroundStyle(vm.isActiveModelReady ? Color.secondary : Color.primary)
      } header: {
        Text("Model")
      } footer: {
        Text("Only MLX-ready Hugging Face repositories are supported. Model weights are downloaded after selection and cached locally by the Hugging Face downloader.")
      }

      Section {
        Button {
          Task { await vm.runTest() }
        } label: {
          Label("Test", systemImage: "speedometer")
        }
        .disabled(!vm.canTest)
      } header: {
        Text("Benchmark")
      } footer: {
        Text("Runs a fixed prompt and reports MLX throughput in TPS.")
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
