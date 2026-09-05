import Foundation

public struct PluginID: RawRepresentable, Codable, Hashable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public var rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.init(rawValue: rawValue) }
  public init(stringLiteral value: String) { self.init(value) }
  public var description: String { rawValue }
}

/// An open-ended capability name. The static values are the extension points
/// understood by MaiCore; future hosts can preserve capabilities they do not
/// yet understand when inspecting a plugin manifest.
public struct PluginCapability: RawRepresentable, Codable, Hashable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public var rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.init(rawValue: rawValue) }
  public init(stringLiteral value: String) { self.init(value) }
  public var description: String { rawValue }

  public static let chatProvider: PluginCapability = "chat-provider"
  public static let agentTool: PluginCapability = "agent-tool"
  public static let ocrProvider: PluginCapability = "ocr-provider"
  public static let mcpToolSource: PluginCapability = "mcp-tool-source"
}

public struct PluginManifest: Codable, Equatable, Identifiable, Sendable {
  /// Version of the in-process Mai plugin API implemented by this plugin.
  public static let currentAPIVersion = 1

  public var id: PluginID
  public var displayName: String
  public var version: String
  public var apiVersion: Int
  public var capabilities: Set<PluginCapability>

  public init(
    id: PluginID,
    displayName: String,
    version: String,
    apiVersion: Int = PluginManifest.currentAPIVersion,
    capabilities: Set<PluginCapability>
  ) {
    self.id = id
    self.displayName = displayName
    self.version = version
    self.apiVersion = apiVersion
    self.capabilities = capabilities
  }
}

/// Context shared by configurable tool and OCR factories. Provider and MCP
/// factories receive their richer typed configurations directly.
public struct PluginFactoryContext: Codable, Equatable, Sendable {
  public var id: String
  public var displayName: String?
  public var options: [String: JSONValue]
  public var environment: [String: String]

  public init(
    id: String,
    displayName: String? = nil,
    options: [String: JSONValue] = [:],
    environment: [String: String] = [:]
  ) {
    self.id = id
    self.displayName = displayName
    self.options = options
    self.environment = environment
  }
}

/// The portable field types a host can render for a tool group's settings.
public enum ToolGroupOptionKind: String, Codable, Equatable, Sendable {
  case text
  case secret
  case boolean
  case number
  case choice
}

public struct ToolGroupOptionDefinition: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  public var help: String?
  public var kind: ToolGroupOptionKind
  public var defaultValue: JSONValue?
  public var choices: [String]

  public init(
    id: String,
    label: String,
    help: String? = nil,
    kind: ToolGroupOptionKind = .text,
    defaultValue: JSONValue? = nil,
    choices: [String] = []
  ) {
    self.id = id
    self.label = label
    self.help = help
    self.kind = kind
    self.defaultValue = defaultValue
    self.choices = choices
  }
}

/// One user-facing capability backed by one or more provider-visible tools.
/// Group IDs are stable configuration identifiers supplied by the plugin.
public struct ToolGroupDefinition: Codable, Equatable, Sendable {
  public var id: String
  public var sourceID: String
  public var displayName: String
  public var description: String
  public var toolNames: Set<String>
  public var options: [ToolGroupOptionDefinition]

  public init(
    id: String,
    sourceID: String = "",
    displayName: String? = nil,
    description: String = "",
    toolNames: Set<String>,
    options: [ToolGroupOptionDefinition] = []
  ) {
    self.id = id
    self.sourceID = sourceID
    self.displayName = displayName ?? id
    self.description = description
    self.toolNames = toolNames
    self.options = options
  }

  public var catalogID: String { sourceID.isEmpty ? id : "\(sourceID)/\(id)" }

  public static func inferred(from tools: [any AgentTool]) -> [ToolGroupDefinition] {
    inferred(from: tools.map(\.definition))
  }

  public static func inferred(from definitions: [ToolDefinition]) -> [ToolGroupDefinition] {
    let grouped = Dictionary(grouping: definitions) { definition in
      definition.name.split(separator: "_", maxSplits: 1).first.map(String.init)
        ?? definition.name
    }
    return grouped.map { id, members in
      let names = Set(members.map(\.name))
      let description =
        members.count == 1
        ? members[0].description
        : "Provides \(names.sorted().joined(separator: ", "))."
      return ToolGroupDefinition(
        id: id,
        displayName: id.replacingOccurrences(of: "_", with: " ").capitalized,
        description: description,
        toolNames: names)
    }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
  }
}

public protocol ConfiguredToolFactory: Sendable {
  var kind: String { get }
  func makeTools(context: PluginFactoryContext) async throws -> [any AgentTool]
  func toolGroups(context: PluginFactoryContext) async throws -> [ToolGroupDefinition]
}

extension ConfiguredToolFactory {
  public func toolGroups(context: PluginFactoryContext) async throws -> [ToolGroupDefinition] {
    ToolGroupDefinition.inferred(from: try await makeTools(context: context))
  }
}

public protocol ConfiguredOCRProviderFactory: Sendable {
  var kind: String { get }
  func makeOCRProvider(context: PluginFactoryContext) throws -> any OCRProvider
}

/// A provider-neutral source of tools discovered from an MCP implementation.
/// HTTP, stdio, embedded, and future MCP transports can all use this boundary.
public protocol MCPToolSource: Sendable {
  func connect() async throws -> MCPServerCatalog
  func agentTools() async throws -> [any AgentTool]
  func close() async
}

public protocol ConfiguredMCPToolSourceFactory: Sendable {
  var kind: String { get }
  func makeMCPToolSource(
    from configuration: ConfiguredMCPServer,
    environment: [String: String]
  ) throws -> any MCPToolSource
}

/// A statically linked Swift plugin implements this protocol directly. Native
/// plugin hosts adapt their stable ABI to the same registration surface.
public protocol MaiPlugin: Sendable {
  var manifest: PluginManifest { get }
  func register(in registry: PluginRegistry) async throws
}

public struct InstalledPlugin: Codable, Equatable, Sendable {
  public var manifest: PluginManifest
  public var origin: String?

  public init(manifest: PluginManifest, origin: String? = nil) {
    self.manifest = manifest
    self.origin = origin
  }
}

/// The single composition point for every host. The actor is mutated only
/// during startup in normal use, while remaining safe for concurrent app and
/// CLI assembly code.
public actor PluginRegistry {
  private struct Registered<Value: Sendable>: Sendable {
    var owner: PluginID
    var value: Value
  }

  private var plugins: [PluginID: InstalledPlugin] = [:]
  private var installingPlugins: Set<PluginID> = []
  private var providerFactories:
    [ConfiguredProviderKind: Registered<any ConfiguredProviderFactory>] = [:]
  private var toolFactories: [String: Registered<any ConfiguredToolFactory>] = [:]
  private var ocrFactories: [String: Registered<any ConfiguredOCRProviderFactory>] = [:]
  private var mcpFactories: [String: Registered<any ConfiguredMCPToolSourceFactory>] = [:]

  public init() {}

  public func install(_ plugin: any MaiPlugin, origin: String? = nil) async throws {
    let manifest = plugin.manifest
    try Self.validate(manifest)
    guard plugins[manifest.id] == nil else {
      throw PluginRegistryError.pluginAlreadyInstalled(manifest.id)
    }
    plugins[manifest.id] = InstalledPlugin(manifest: manifest, origin: origin)
    installingPlugins.insert(manifest.id)
    do {
      try await plugin.register(in: self)
      try validateDeclaredCapabilities(for: manifest.id)
      installingPlugins.remove(manifest.id)
    } catch {
      removeRegistrations(ownedBy: manifest.id)
      installingPlugins.remove(manifest.id)
      plugins[manifest.id] = nil
      throw error
    }
  }

  public func installedPlugins() -> [InstalledPlugin] {
    plugins.values.sorted {
      $0.manifest.id.rawValue.localizedStandardCompare($1.manifest.id.rawValue)
        == .orderedAscending
    }
  }

  public func register(
    providerFactory: any ConfiguredProviderFactory,
    from pluginID: PluginID
  ) throws {
    try requireInstallingPlugin(pluginID, capability: .chatProvider)
    guard providerFactories[providerFactory.kind] == nil else {
      throw PluginRegistryError.factoryAlreadyRegistered(
        capability: .chatProvider,
        kind: providerFactory.kind.rawValue)
    }
    providerFactories[providerFactory.kind] = Registered(owner: pluginID, value: providerFactory)
  }

  public func register(
    toolFactory: any ConfiguredToolFactory,
    from pluginID: PluginID
  ) throws {
    try requireInstallingPlugin(pluginID, capability: .agentTool)
    try register(
      toolFactory, kind: toolFactory.kind, capability: .agentTool, owner: pluginID,
      into: &toolFactories)
  }

  public func register(
    ocrFactory: any ConfiguredOCRProviderFactory,
    from pluginID: PluginID
  ) throws {
    try requireInstallingPlugin(pluginID, capability: .ocrProvider)
    try register(
      ocrFactory, kind: ocrFactory.kind, capability: .ocrProvider, owner: pluginID,
      into: &ocrFactories)
  }

  public func register(
    mcpFactory: any ConfiguredMCPToolSourceFactory,
    from pluginID: PluginID
  ) throws {
    try requireInstallingPlugin(pluginID, capability: .mcpToolSource)
    try register(
      mcpFactory, kind: mcpFactory.kind, capability: .mcpToolSource, owner: pluginID,
      into: &mcpFactories)
  }

  public func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    guard let registered = providerFactories[configuration.kind] else {
      throw PluginRegistryError.factoryNotRegistered(
        capability: .chatProvider,
        kind: configuration.kind.rawValue)
    }
    return try registered.value.makeProvider(from: configuration, environment: environment)
  }

  public func makeTools(
    kind: String,
    context: PluginFactoryContext
  ) async throws -> [any AgentTool] {
    guard let registered = toolFactories[kind] else {
      throw PluginRegistryError.factoryNotRegistered(capability: .agentTool, kind: kind)
    }
    return try await registered.value.makeTools(context: context)
  }

  public func toolGroups(
    kind: String,
    context: PluginFactoryContext
  ) async throws -> [ToolGroupDefinition] {
    guard let registered = toolFactories[kind] else {
      throw PluginRegistryError.factoryNotRegistered(capability: .agentTool, kind: kind)
    }
    return try await registered.value.toolGroups(context: context).map { definition in
      var definition = definition
      definition.sourceID = context.id
      return definition
    }
  }

  public func makeOCRProvider(
    kind: String,
    context: PluginFactoryContext
  ) throws -> any OCRProvider {
    guard let registered = ocrFactories[kind] else {
      throw PluginRegistryError.factoryNotRegistered(capability: .ocrProvider, kind: kind)
    }
    return try registered.value.makeOCRProvider(context: context)
  }

  public func makeMCPToolSource(
    kind: String,
    configuration: ConfiguredMCPServer,
    environment: [String: String]
  ) throws -> any MCPToolSource {
    guard let registered = mcpFactories[kind] else {
      throw PluginRegistryError.factoryNotRegistered(capability: .mcpToolSource, kind: kind)
    }
    return try registered.value.makeMCPToolSource(
      from: configuration,
      environment: environment)
  }

  private func requireInstallingPlugin(
    _ pluginID: PluginID,
    capability: PluginCapability
  ) throws {
    guard let plugin = plugins[pluginID], installingPlugins.contains(pluginID) else {
      throw PluginRegistryError.pluginNotInstalled(pluginID)
    }
    guard plugin.manifest.capabilities.contains(capability) else {
      throw PluginRegistryError.undeclaredCapability(plugin: pluginID, capability: capability)
    }
  }

  private func register<Value: Sendable>(
    _ value: Value,
    kind: String,
    capability: PluginCapability,
    owner: PluginID,
    into factories: inout [String: Registered<Value>]
  ) throws {
    let normalized = kind.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw PluginRegistryError.invalidFactoryKind(capability)
    }
    guard factories[normalized] == nil else {
      throw PluginRegistryError.factoryAlreadyRegistered(capability: capability, kind: normalized)
    }
    factories[normalized] = Registered(owner: owner, value: value)
  }

  private func validateDeclaredCapabilities(for pluginID: PluginID) throws {
    guard let manifest = plugins[pluginID]?.manifest else { return }
    let capabilities: [PluginCapability?] = [
      providerFactories.values.contains { $0.owner == pluginID }
        ? PluginCapability.chatProvider : nil,
      toolFactories.values.contains { $0.owner == pluginID } ? PluginCapability.agentTool : nil,
      ocrFactories.values.contains { $0.owner == pluginID }
        ? PluginCapability.ocrProvider : nil,
      mcpFactories.values.contains { $0.owner == pluginID }
        ? PluginCapability.mcpToolSource : nil,
    ]
    let registered = Set(capabilities.compactMap { $0 })
    let missing = manifest.capabilities.subtracting(registered)
    if let capability = missing.sorted(by: { $0.rawValue < $1.rawValue }).first {
      throw PluginRegistryError.missingRegistration(plugin: pluginID, capability: capability)
    }
  }

  private func removeRegistrations(ownedBy pluginID: PluginID) {
    providerFactories = providerFactories.filter { $0.value.owner != pluginID }
    toolFactories = toolFactories.filter { $0.value.owner != pluginID }
    ocrFactories = ocrFactories.filter { $0.value.owner != pluginID }
    mcpFactories = mcpFactories.filter { $0.value.owner != pluginID }
  }

  private static func validate(_ manifest: PluginManifest) throws {
    let id = manifest.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw PluginRegistryError.invalidPluginID }
    guard manifest.apiVersion == PluginManifest.currentAPIVersion else {
      throw PluginRegistryError.unsupportedAPIVersion(
        plugin: manifest.id,
        found: manifest.apiVersion,
        supported: PluginManifest.currentAPIVersion)
    }
  }
}

public enum PluginRegistryError: LocalizedError, Equatable, Sendable {
  case invalidPluginID
  case unsupportedAPIVersion(plugin: PluginID, found: Int, supported: Int)
  case pluginAlreadyInstalled(PluginID)
  case pluginNotInstalled(PluginID)
  case undeclaredCapability(plugin: PluginID, capability: PluginCapability)
  case missingRegistration(plugin: PluginID, capability: PluginCapability)
  case invalidFactoryKind(PluginCapability)
  case factoryAlreadyRegistered(capability: PluginCapability, kind: String)
  case factoryNotRegistered(capability: PluginCapability, kind: String)

  public var errorDescription: String? {
    switch self {
    case .invalidPluginID:
      "Plugin identifiers must not be empty."
    case .unsupportedAPIVersion(let plugin, let found, let supported):
      "Plugin '\(plugin)' uses API version \(found); this host supports version \(supported)."
    case .pluginAlreadyInstalled(let plugin):
      "Plugin '\(plugin)' is already installed."
    case .pluginNotInstalled(let plugin):
      "Plugin '\(plugin)' must be installed before registering factories."
    case .undeclaredCapability(let plugin, let capability):
      "Plugin '\(plugin)' did not declare capability '\(capability)'."
    case .missingRegistration(let plugin, let capability):
      "Plugin '\(plugin)' declared '\(capability)' but did not register a factory."
    case .invalidFactoryKind(let capability):
      "A factory kind for '\(capability)' must not be empty."
    case .factoryAlreadyRegistered(let capability, let kind):
      "A '\(capability)' factory for '\(kind)' is already registered."
    case .factoryNotRegistered(let capability, let kind):
      "No '\(capability)' factory is registered for '\(kind)'."
    }
  }
}
