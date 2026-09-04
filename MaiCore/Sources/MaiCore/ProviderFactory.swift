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

/// A startup-time registry that maps open-ended configuration kinds to provider
/// implementations. It is a value type so each host can assemble an isolated
/// set of supported providers before constructing its runtime.
public struct ProviderFactoryRegistry: Sendable {
  private var factories: [ConfiguredProviderKind: any ConfiguredProviderFactory]

  public init(includeStandardFactories: Bool = true) {
    factories = [:]
    if includeStandardFactories {
      factories[.hello] = HelloConfiguredProviderFactory()
      factories[.openAICompatible] = OpenAIConfiguredProviderFactory()
    }
  }

  public var registeredKinds: [ConfiguredProviderKind] {
    factories.keys.sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending }
  }

  public func contains(_ kind: ConfiguredProviderKind) -> Bool {
    factories[kind] != nil
  }

  public mutating func register(
    _ factory: any ConfiguredProviderFactory,
    replacingExisting: Bool = false
  ) throws {
    guard replacingExisting || factories[factory.kind] == nil else {
      throw MaiConfigurationError.providerFactoryAlreadyRegistered(factory.kind.rawValue)
    }
    factories[factory.kind] = factory
  }

  public func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    guard let factory = factories[configuration.kind] else {
      throw MaiConfigurationError.providerFactoryNotRegistered(configuration.kind.rawValue)
    }
    return try factory.makeProvider(from: configuration, environment: environment)
  }
}

private struct HelloConfiguredProviderFactory: ConfiguredProviderFactory {
  let kind = ConfiguredProviderKind.hello

  func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    HelloProvider(
      id: ProviderID(configuration.id),
      displayName: configuration.displayName ?? "MaiCore Hello")
  }
}

private struct OpenAIConfiguredProviderFactory: ConfiguredProviderFactory {
  let kind = ConfiguredProviderKind.openAICompatible

  func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    guard let baseURL = configuration.baseURL else {
      throw MaiConfigurationError.providerMissingBaseURL(configuration.id)
    }
    return OpenAICompatibleProvider(
      configuration: .init(
        id: ProviderID(configuration.id),
        displayName: configuration.displayName ?? "OpenAI-compatible",
        baseURL: baseURL,
        apiKey: configuration.resolvedAPIKey(environment: environment),
        additionalHeaders: try configuration.resolvedHeaders(environment: environment),
        requestTimeout: configuration.timeout ?? 600))
  }
}
