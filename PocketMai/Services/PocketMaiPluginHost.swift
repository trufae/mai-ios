import Foundation
import MaiCore
import MaiOpenAI

/// PocketMai's static composition root. iOS cannot load arbitrary unsigned
/// dylibs, so app integrations use the same MaiPlugin API as the CLI while
/// remaining normal, code-signed Swift modules in the application bundle.
actor PocketMaiPluginHost {
  static let shared = PocketMaiPluginHost()

  private let registry = PluginRegistry()
  private var startup: Task<Void, Error>?

  private init() {}

  func makeOpenAIProvider(
    endpoint: OpenAIEndpoint,
    requestTimeout: TimeInterval = 600
  ) async throws -> any ChatProvider {
    try await prepare()
    guard let baseURL = URL(string: endpoint.baseURL) else {
      throw ChatProviderError.invalidEndpoint(endpoint.baseURL)
    }
    return try await registry.makeProvider(
      from: ConfiguredProvider(
        id: endpoint.id.uuidString,
        kind: .openAICompatible,
        displayName: endpoint.name,
        baseURL: baseURL,
        apiKey: endpoint.apiKey,
        timeout: requestTimeout),
      environment: [:])
  }

  func makeOCRProvider() async throws -> any OCRProvider {
    try await prepare()
    return try await registry.makeOCRProvider(
      kind: "pocketmai-vision",
      context: PluginFactoryContext(id: "pocketmai-vision"))
  }

  func installedPlugins() async throws -> [InstalledPlugin] {
    try await prepare()
    return await registry.installedPlugins()
  }

  private func prepare() async throws {
    if let startup {
      return try await startup.value
    }
    let registry = registry
    let task = Task {
      try await registry.install(MaiOpenAIPlugin(), origin: "PocketMai")
      try await registry.install(PocketMaiPlatformPlugin(), origin: "PocketMai")
    }
    startup = task
    do {
      try await task.value
    } catch {
      startup = nil
      throw error
    }
  }
}

private struct PocketMaiPlatformPlugin: MaiPlugin {
  let manifest = PluginManifest(
    id: "org.mai.pocketmai-platform",
    displayName: "PocketMai platform integrations",
    version: "1.0.0",
    capabilities: [.ocrProvider])

  func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      ocrFactory: PocketMaiOCRFactory(),
      from: manifest.id)
  }
}

private struct PocketMaiOCRFactory: ConfiguredOCRProviderFactory {
  let kind = "pocketmai-vision"

  func makeOCRProvider(context: PluginFactoryContext) throws -> any OCRProvider {
    PocketMaiOCRProvider()
  }
}
