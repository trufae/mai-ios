import Foundation
import SwiftUI

import MLX
import MLXLLM
import MLXLMCommon
import MLXLMHFAPI
import MLXLMTokenizers

@MainActor
final class LocalLLMViewModel: ObservableObject {
  static let defaultModelId = "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit"

  @Published var selectedModelId = LocalLLMViewModel.defaultModelId
  @Published var customModelId = ""
  @Published var prompt = "Write a short welcome message."
  @Published var output = ""
  @Published var status = "Choose an MLX-ready Hugging Face repo."
  @Published var isLoading = false
  @Published var isReady = false
  @Published var downloadProgress: Double?

  let presets = [
    "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit",
    "mlx-community/LFM2-350M-MLX",
    "mlx-community/LFM2-2.6B-4bit",
    "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
  ]

  private var container: ModelContainer?
  private var loadedModelId: String?

  var activeModelId: String {
    let custom = customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    return custom.isEmpty ? selectedModelId : custom
  }

  var canGenerate: Bool {
    isReady && !isLoading && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    output = "Loading model: \(modelId)"
    status = "Preparing Hugging Face download..."
    defer {
      isLoading = false
      downloadProgress = nil
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
      output = "Model ready: \(modelId)"
    } catch is CancellationError {
      status = "Model load cancelled."
      output = status
    } catch {
      container = nil
      loadedModelId = nil
      showFailure(error, action: "Model load", modelId: modelId)
    }
  }

  func generate() async {
    guard let container else {
      output = "Load a model first."
      status = output
      return
    }

    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      showFailure(LocalLLMError.emptyPrompt, action: "Generation", modelId: loadedModelId ?? activeModelId)
      return
    }

    isLoading = true
    output = ""
    status = "Generating..."
    defer { isLoading = false }

    do {
      let input = try await container.prepare(input: UserInput(prompt: trimmedPrompt))
      let stream = try await container.generate(
        input: input,
        parameters: GenerateParameters(maxTokens: 256, temperature: 0.7)
      )

      var generatedText = ""
      for await generation in stream {
        try Task.checkCancellation()
        switch generation {
        case .chunk(let text):
          generatedText += text
          output = generatedText
        case .info(let info):
          status =
            "Finished \(info.generationTokenCount) tokens at "
            + "\(info.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tokens/s."
        case .toolCall(let toolCall):
          generatedText += "\n\n[Tool call: \(toolCall.function.name)]"
          output = generatedText
        }
      }
    } catch is CancellationError {
      status = "Generation cancelled."
    } catch {
      showFailure(error, action: "Generation", modelId: loadedModelId ?? activeModelId)
    }
  }

  private func showFailure(_ error: Error, action: String, modelId: String) {
    let message = Self.message(for: error, action: action, modelId: modelId)
    isReady = container != nil && loadedModelId != nil
    status = message
    output = message
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

private enum LocalLLMError: LocalizedError {
  case invalidModelID(String)
  case emptyPrompt

  var errorDescription: String? {
    switch self {
    case .invalidModelID(let id):
      if id.isEmpty {
        return "Enter a Hugging Face repo id in the form org/model-name."
      }
      return "Invalid model id: \(id). Use a Hugging Face repo id in the form org/model-name, not a URL or local path."
    case .emptyPrompt:
      return "Enter a prompt before generating."
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
            vm.isReady ? "Reload Model" : "Download / Load Model",
            systemImage: vm.isReady ? "arrow.clockwise" : "arrow.down.circle"
          )
        }
        .disabled(vm.isLoading)

        Text(vm.status)
          .font(.caption)
          .foregroundStyle(vm.isReady ? Color.secondary : Color.primary)
      } header: {
        Text("Model")
      } footer: {
        Text("Only MLX-ready Hugging Face repositories are supported. Model weights are downloaded after selection and cached locally by the Hugging Face downloader.")
      }

      Section("Prompt") {
        TextEditor(text: $vm.prompt)
          .frame(minHeight: 120)

        Button {
          Task { await vm.generate() }
        } label: {
          Label("Generate", systemImage: "text.bubble")
        }
        .disabled(!vm.canGenerate)
      }

      Section("Output") {
        ScrollView {
          Text(vm.output)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minHeight: 220)
      }
    }
    .navigationTitle("Local MLX LLM")
  }
}
