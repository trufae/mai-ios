import Foundation

/// Converts one configuration record into a provider implementation. Hosts can
/// register additional factories without modifying MaiCore's configuration
/// schema or provider switch statements.
public protocol ConfiguredProviderFactory: Sendable {
  var kind: ConfiguredProviderKind { get }

  func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider
}

public struct HelloConfiguredProviderFactory: ConfiguredProviderFactory {
  public let kind = ConfiguredProviderKind.hello

  public init() {}

  public func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    HelloProvider(
      id: ProviderID(configuration.id),
      displayName: configuration.displayName ?? "MaiCore Hello")
  }
}

/// The intentionally small plugin shipped by the core module itself. It only
/// provides the deterministic hello backend used by examples and tests.
public struct MaiCoreBuiltinsPlugin: MaiPlugin {
  public let manifest = PluginManifest(
    id: "org.mai.core-builtins",
    displayName: "MaiCore built-ins",
    version: "1.0.0",
    capabilities: [.chatProvider, .ocrProvider, .mcpToolSource])

  public init() {}

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      providerFactory: HelloConfiguredProviderFactory(),
      from: manifest.id)
    try await registry.register(
      ocrFactory: VisionConfiguredOCRProviderFactory(),
      from: manifest.id)
    try await registry.register(
      mcpFactory: StreamableHTTPMCPFactory(),
      from: manifest.id)
  }
}

public struct VisionConfiguredOCRProviderFactory: ConfiguredOCRProviderFactory {
  public let kind = "vision"

  public init() {}

  public func makeOCRProvider(context: PluginFactoryContext) throws -> any OCRProvider {
    VisionOCRProvider()
  }
}

public struct StreamableHTTPMCPFactory: ConfiguredMCPToolSourceFactory {
  public let kind = "streamable-http"

  public init() {}

  public func makeMCPToolSource(
    from configuration: ConfiguredMCPServer,
    environment: [String: String]
  ) throws -> any MCPToolSource {
    MCPClient(configuration: try configuration.resolved(environment: environment))
  }
}
