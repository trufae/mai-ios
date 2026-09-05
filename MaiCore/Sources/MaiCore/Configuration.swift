import Foundation

/// An open-ended configuration discriminator. MaiCore reserves the static
/// values below for its built-in factories; hosts may define any other value.
public struct ConfiguredProviderKind: RawRepresentable, Codable, Hashable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public var rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.init(rawValue: rawValue) }
  public init(stringLiteral value: String) { self.init(value) }
  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let hello: ConfiguredProviderKind = "hello"
  public static let openAICompatible: ConfiguredProviderKind = "openAICompatible"
}

public struct ConfiguredProvider: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: ConfiguredProviderKind
  public var displayName: String?
  public var baseURL: URL?
  public var apiKey: String?
  public var apiKeyEnvironment: String?
  public var headers: [String: String]
  public var headerEnvironment: [String: String]
  public var timeout: TimeInterval?
  /// Provider-specific settings preserved by the shared configuration format.
  public var options: [String: JSONValue]

  public init(
    id: String,
    kind: ConfiguredProviderKind,
    displayName: String? = nil,
    baseURL: URL? = nil,
    apiKey: String? = nil,
    apiKeyEnvironment: String? = nil,
    headers: [String: String] = [:],
    headerEnvironment: [String: String] = [:],
    timeout: TimeInterval? = nil,
    options: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.displayName = displayName
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.apiKeyEnvironment = apiKeyEnvironment
    self.headers = headers
    self.headerEnvironment = headerEnvironment
    self.timeout = timeout
    self.options = options
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, displayName, baseURL, apiKey, apiKeyEnvironment, headers, headerEnvironment,
      timeout
    case options
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      kind: try container.decode(ConfiguredProviderKind.self, forKey: .kind),
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      baseURL: try container.decodeIfPresent(URL.self, forKey: .baseURL),
      apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey),
      apiKeyEnvironment: try container.decodeIfPresent(String.self, forKey: .apiKeyEnvironment),
      headers: try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
      headerEnvironment: try container.decodeIfPresent(
        [String: String].self,
        forKey: .headerEnvironment) ?? [:],
      timeout: try container.decodeIfPresent(TimeInterval.self, forKey: .timeout),
      options: try container.decodeIfPresent([String: JSONValue].self, forKey: .options) ?? [:])
  }

  public func resolvedHeaders(environment: [String: String]) throws -> [String: String] {
    var resolved = headers
    for (header, environmentName) in headerEnvironment {
      guard let value = environment[environmentName], !value.isEmpty else {
        throw MaiConfigurationError.missingEnvironmentVariable(environmentName)
      }
      resolved[header] = value
    }
    return resolved
  }

  public func resolvedAPIKey(environment: [String: String]) -> String? {
    guard let apiKeyEnvironment, !apiKeyEnvironment.isEmpty else { return apiKey }
    return environment[apiKeyEnvironment].flatMap { $0.isEmpty ? nil : $0 } ?? apiKey
  }
}

public struct ConfiguredPlugin: Codable, Equatable, Sendable {
  public var path: String
  public var enabled: Bool
  public var required: Bool

  public init(path: String, enabled: Bool = true, required: Bool = true) {
    self.path = path
    self.enabled = enabled
    self.required = required
  }

  private enum CodingKeys: String, CodingKey { case path, enabled, required }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      path: try container.decode(String.self, forKey: .path),
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      required: try container.decodeIfPresent(Bool.self, forKey: .required) ?? true)
  }
}

public struct ConfiguredToolSource: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: String
  public var enabled: Bool
  public var displayName: String?
  public var options: [String: JSONValue]

  public init(
    id: String,
    kind: String,
    enabled: Bool = true,
    displayName: String? = nil,
    options: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.enabled = enabled
    self.displayName = displayName
    self.options = options
  }

  private enum CodingKeys: String, CodingKey { case id, kind, enabled, displayName, options }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      kind: try container.decode(String.self, forKey: .kind),
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      options: try container.decodeIfPresent([String: JSONValue].self, forKey: .options) ?? [:])
  }

  public func context(environment: [String: String]) -> PluginFactoryContext {
    PluginFactoryContext(
      id: id,
      displayName: displayName,
      options: options,
      environment: environment)
  }
}

public struct ConfiguredOCRProvider: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: String
  public var enabled: Bool
  public var displayName: String?
  public var options: [String: JSONValue]

  public init(
    id: String,
    kind: String,
    enabled: Bool = true,
    displayName: String? = nil,
    options: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.enabled = enabled
    self.displayName = displayName
    self.options = options
  }

  private enum CodingKeys: String, CodingKey { case id, kind, enabled, displayName, options }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      kind: try container.decode(String.self, forKey: .kind),
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      options: try container.decodeIfPresent([String: JSONValue].self, forKey: .options) ?? [:])
  }

  public func context(environment: [String: String]) -> PluginFactoryContext {
    PluginFactoryContext(
      id: id,
      displayName: displayName,
      options: options,
      environment: environment)
  }
}

public struct ConfiguredMCPServer: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: String
  public var enabled: Bool
  public var displayName: String?
  public var url: URL?
  public var headers: [String: String]
  public var headerEnvironment: [String: String]
  public var bearerToken: String?
  public var bearerTokenEnvironment: String?
  public var timeout: TimeInterval?
  public var toolNamePrefix: String?
  public var defaultApproval: ToolApprovalRequirement
  public var options: [String: JSONValue]

  public init(
    id: String,
    kind: String = "streamable-http",
    enabled: Bool = true,
    displayName: String? = nil,
    url: URL? = nil,
    headers: [String: String] = [:],
    headerEnvironment: [String: String] = [:],
    bearerToken: String? = nil,
    bearerTokenEnvironment: String? = nil,
    timeout: TimeInterval? = nil,
    toolNamePrefix: String? = nil,
    defaultApproval: ToolApprovalRequirement = .confirm,
    options: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.enabled = enabled
    self.displayName = displayName
    self.url = url
    self.headers = headers
    self.headerEnvironment = headerEnvironment
    self.bearerToken = bearerToken
    self.bearerTokenEnvironment = bearerTokenEnvironment
    self.timeout = timeout
    self.toolNamePrefix = toolNamePrefix
    self.defaultApproval = defaultApproval
    self.options = options
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, enabled, displayName, url, headers, headerEnvironment, bearerToken
    case bearerTokenEnvironment
    case timeout, toolNamePrefix, defaultApproval, options
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      kind: try container.decodeIfPresent(String.self, forKey: .kind) ?? "streamable-http",
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      url: try container.decodeIfPresent(URL.self, forKey: .url),
      headers: try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
      headerEnvironment: try container.decodeIfPresent(
        [String: String].self,
        forKey: .headerEnvironment) ?? [:],
      bearerToken: try container.decodeIfPresent(String.self, forKey: .bearerToken),
      bearerTokenEnvironment: try container.decodeIfPresent(
        String.self,
        forKey: .bearerTokenEnvironment),
      timeout: try container.decodeIfPresent(TimeInterval.self, forKey: .timeout),
      toolNamePrefix: try container.decodeIfPresent(String.self, forKey: .toolNamePrefix),
      defaultApproval: try container.decodeIfPresent(
        ToolApprovalRequirement.self,
        forKey: .defaultApproval) ?? .confirm,
      options: try container.decodeIfPresent([String: JSONValue].self, forKey: .options) ?? [:])
  }

  public func resolved(environment: [String: String]) throws -> MCPServerConfiguration {
    guard let url else { throw MaiConfigurationError.mcpServerMissingURL(id) }
    var resolvedHeaders = headers
    for (header, environmentName) in headerEnvironment {
      guard let value = environment[environmentName], !value.isEmpty else {
        throw MaiConfigurationError.missingEnvironmentVariable(environmentName)
      }
      resolvedHeaders[header] = value
    }
    let token: String?
    if let bearerTokenEnvironment, !bearerTokenEnvironment.isEmpty {
      guard let value = environment[bearerTokenEnvironment], !value.isEmpty else {
        throw MaiConfigurationError.missingEnvironmentVariable(bearerTokenEnvironment)
      }
      token = value
    } else {
      token = bearerToken
    }
    if let token, !token.isEmpty {
      resolvedHeaders["Authorization"] = "Bearer \(token)"
    }
    return MCPServerConfiguration(
      id: id,
      displayName: displayName,
      url: url,
      headers: resolvedHeaders,
      timeout: timeout ?? 60,
      toolNamePrefix: toolNamePrefix,
      defaultApproval: defaultApproval)
  }
}

public enum ConfiguredApprovalMode: String, Codable, Sendable {
  case ask
  case allow
  case deny
}

public struct ConfiguredApprovals: Codable, Equatable, Sendable {
  public var confirm: ConfiguredApprovalMode
  public var dangerous: ConfiguredApprovalMode

  public init(
    confirm: ConfiguredApprovalMode = .ask,
    dangerous: ConfiguredApprovalMode = .ask
  ) {
    self.confirm = confirm
    self.dangerous = dangerous
  }

  private enum CodingKeys: String, CodingKey { case confirm, dangerous }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      confirm: try container.decodeIfPresent(ConfiguredApprovalMode.self, forKey: .confirm) ?? .ask,
      dangerous: try container.decodeIfPresent(ConfiguredApprovalMode.self, forKey: .dangerous)
        ?? .ask)
  }
}

public struct ConfiguredTerminalUI: Codable, Equatable, Sendable {
  public var backgroundLine: String
  public var foreground: String
  public var background: String
  public var promptForeground: String
  public var promptBackground: String
  public var bold: Bool
  /// Render assistant replies as styled markdown in the REPL and visual mode.
  public var markdown: Bool

  public init(
    backgroundLine: String = "blue",
    foreground: String = "",
    background: String = "",
    promptForeground: String = "yellow",
    promptBackground: String = "",
    bold: Bool = false,
    markdown: Bool = true
  ) {
    self.backgroundLine = backgroundLine
    self.foreground = foreground
    self.background = background
    self.promptForeground = promptForeground
    self.promptBackground = promptBackground
    self.bold = bold
    self.markdown = markdown
  }

  private enum CodingKeys: String, CodingKey {
    case backgroundLine = "bgline"
    case foreground = "fgcolor"
    case background = "bgcolor"
    case promptForeground = "fgprompt"
    case promptBackground = "bgprompt"
    case bold
    case markdown
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      backgroundLine: try container.decodeIfPresent(String.self, forKey: .backgroundLine) ?? "blue",
      foreground: try container.decodeIfPresent(String.self, forKey: .foreground) ?? "",
      background: try container.decodeIfPresent(String.self, forKey: .background) ?? "",
      promptForeground: try container.decodeIfPresent(String.self, forKey: .promptForeground)
        ?? "yellow",
      promptBackground: try container.decodeIfPresent(String.self, forKey: .promptBackground) ?? "",
      bold: try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false,
      markdown: try container.decodeIfPresent(Bool.self, forKey: .markdown) ?? true)
  }
}

public struct MaiConfiguration: Codable, Equatable, Sendable {
  public var version: Int
  public var defaultAgent: String?
  public var plugins: [ConfiguredPlugin]
  public var providers: [ConfiguredProvider]
  public var toolSources: [ConfiguredToolSource]
  public var ocrProviders: [ConfiguredOCRProvider]
  public var mcpServers: [ConfiguredMCPServer]
  public var agents: [AgentDefinition]
  public var ui: ConfiguredTerminalUI
  public var approvals: ConfiguredApprovals

  public init(
    version: Int = 1,
    defaultAgent: String? = nil,
    plugins: [ConfiguredPlugin] = [],
    providers: [ConfiguredProvider] = [],
    toolSources: [ConfiguredToolSource] = [],
    ocrProviders: [ConfiguredOCRProvider] = [],
    mcpServers: [ConfiguredMCPServer] = [],
    agents: [AgentDefinition] = [],
    ui: ConfiguredTerminalUI = .init(),
    approvals: ConfiguredApprovals = .init()
  ) {
    self.version = version
    self.defaultAgent = defaultAgent
    self.plugins = plugins
    self.providers = providers
    self.toolSources = toolSources
    self.ocrProviders = ocrProviders
    self.mcpServers = mcpServers
    self.agents = agents
    self.ui = ui
    self.approvals = approvals
  }

  private enum CodingKeys: String, CodingKey {
    case version, defaultAgent, plugins, providers, toolSources, ocrProviders, mcpServers, agents,
      ui,
      approvals
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
      defaultAgent: try container.decodeIfPresent(String.self, forKey: .defaultAgent),
      plugins: try container.decodeIfPresent([ConfiguredPlugin].self, forKey: .plugins) ?? [],
      providers: try container.decodeIfPresent([ConfiguredProvider].self, forKey: .providers) ?? [],
      toolSources: try container.decodeIfPresent([ConfiguredToolSource].self, forKey: .toolSources)
        ?? [],
      ocrProviders: try container.decodeIfPresent(
        [ConfiguredOCRProvider].self,
        forKey: .ocrProviders) ?? [],
      mcpServers: try container.decodeIfPresent([ConfiguredMCPServer].self, forKey: .mcpServers)
        ?? [],
      agents: try container.decodeIfPresent([AgentDefinition].self, forKey: .agents) ?? [],
      ui: try container.decodeIfPresent(ConfiguredTerminalUI.self, forKey: .ui) ?? .init(),
      approvals: try container.decodeIfPresent(ConfiguredApprovals.self, forKey: .approvals)
        ?? .init())
  }

  public static func load(from url: URL) throws -> MaiConfiguration {
    let data = try Data(contentsOf: url)
    do {
      let configuration = try JSONDecoder().decode(MaiConfiguration.self, from: data)
      try configuration.validate()
      return configuration
    } catch let error as MaiConfigurationError {
      throw error
    } catch {
      throw MaiConfigurationError.invalidFile(error.localizedDescription)
    }
  }

  public func encoded(prettyPrinted: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
    return try encoder.encode(self)
  }

  public func save(to url: URL, prettyPrinted: Bool = true) throws {
    try validate()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try encoded(prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
  }

  public func validate() throws {
    guard version == 1 else { throw MaiConfigurationError.unsupportedVersion(version) }
    try Self.requireUnique(providers.map(\.id), kind: "provider")
    try Self.requireUnique(toolSources.map(\.id), kind: "tool source")
    try Self.requireUnique(ocrProviders.map(\.id), kind: "OCR provider")
    try Self.requireUnique(mcpServers.map(\.id), kind: "MCP server")
    try Self.requireUnique(agents.map(\.id), kind: "agent")
    let providerIDs = Set(providers.map(\.id))
    let agentIDs = Set(agents.map(\.id))
    if let defaultAgent, !agentIDs.contains(defaultAgent) {
      throw MaiConfigurationError.unknownAgent(defaultAgent)
    }
    for agent in agents {
      guard providerIDs.contains(agent.provider.rawValue) else {
        throw MaiConfigurationError.unknownProvider(agent.provider.rawValue)
      }
      for child in agent.subagentNames where !agentIDs.contains(child) {
        throw MaiConfigurationError.unknownAgent(child)
      }
    }
  }

  private static func requireUnique(_ values: [String], kind: String) throws {
    var seen = Set<String>()
    for rawValue in values {
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { throw MaiConfigurationError.emptyIdentifier(kind) }
      guard seen.insert(value).inserted else {
        throw MaiConfigurationError.duplicateIdentifier(kind: kind, id: value)
      }
    }
  }
}

public enum MaiConfigurationError: LocalizedError, Equatable, Sendable {
  case invalidFile(String)
  case unsupportedVersion(Int)
  case emptyIdentifier(String)
  case duplicateIdentifier(kind: String, id: String)
  case providerMissingBaseURL(String)
  case mcpServerMissingURL(String)
  case unknownProvider(String)
  case unknownAgent(String)
  case unknownTool(agent: String, tool: String)
  case missingEnvironmentVariable(String)

  public var errorDescription: String? {
    switch self {
    case .invalidFile(let message):
      "Invalid Mai configuration: \(message)"
    case .unsupportedVersion(let version):
      "Unsupported Mai configuration version \(version)."
    case .emptyIdentifier(let kind):
      "A \(kind) identifier is empty."
    case .duplicateIdentifier(let kind, let id):
      "Duplicate \(kind) identifier '\(id)'."
    case .providerMissingBaseURL(let id):
      "OpenAI-compatible provider '\(id)' is missing baseURL."
    case .mcpServerMissingURL(let id):
      "MCP server '\(id)' is missing a URL."
    case .unknownProvider(let id):
      "Configuration references unknown provider '\(id)'."
    case .unknownAgent(let id):
      "Configuration references unknown agent '\(id)'."
    case .unknownTool(let agent, let tool):
      "Agent '\(agent)' references unknown tool '\(tool)'."
    case .missingEnvironmentVariable(let name):
      "Required environment variable '\(name)' is not set."
    }
  }
}
