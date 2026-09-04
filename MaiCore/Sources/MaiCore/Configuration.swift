import Foundation

public enum ConfiguredProviderKind: String, Codable, Sendable {
  case hello
  case openAICompatible
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

  public init(
    id: String,
    kind: ConfiguredProviderKind,
    displayName: String? = nil,
    baseURL: URL? = nil,
    apiKey: String? = nil,
    apiKeyEnvironment: String? = nil,
    headers: [String: String] = [:],
    headerEnvironment: [String: String] = [:],
    timeout: TimeInterval? = nil
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
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, displayName, baseURL, apiKey, apiKeyEnvironment, headers, headerEnvironment,
      timeout
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
      timeout: try container.decodeIfPresent(TimeInterval.self, forKey: .timeout))
  }

  public func makeProvider(environment: [String: String]) throws -> any ChatProvider {
    switch kind {
    case .hello:
      return HelloProvider(
        id: ProviderID(id),
        displayName: displayName ?? "MaiCore Hello")
    case .openAICompatible:
      guard let baseURL else { throw MaiConfigurationError.providerMissingBaseURL(id) }
      var resolvedHeaders = headers
      for (header, environmentName) in headerEnvironment {
        guard let value = environment[environmentName], !value.isEmpty else {
          throw MaiConfigurationError.missingEnvironmentVariable(environmentName)
        }
        resolvedHeaders[header] = value
      }
      let resolvedKey: String?
      if let apiKeyEnvironment, !apiKeyEnvironment.isEmpty {
        resolvedKey = environment[apiKeyEnvironment].flatMap { $0.isEmpty ? nil : $0 } ?? apiKey
      } else {
        resolvedKey = apiKey
      }
      return OpenAICompatibleProvider(
        configuration: .init(
          id: ProviderID(id),
          displayName: displayName ?? "OpenAI-compatible",
          baseURL: baseURL,
          apiKey: resolvedKey,
          additionalHeaders: resolvedHeaders,
          requestTimeout: timeout ?? 600))
    }
  }
}

public struct ConfiguredMCPServer: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var enabled: Bool
  public var displayName: String?
  public var url: URL
  public var headers: [String: String]
  public var headerEnvironment: [String: String]
  public var bearerToken: String?
  public var bearerTokenEnvironment: String?
  public var timeout: TimeInterval?
  public var toolNamePrefix: String?
  public var defaultApproval: ToolApprovalRequirement

  public init(
    id: String,
    enabled: Bool = true,
    displayName: String? = nil,
    url: URL,
    headers: [String: String] = [:],
    headerEnvironment: [String: String] = [:],
    bearerToken: String? = nil,
    bearerTokenEnvironment: String? = nil,
    timeout: TimeInterval? = nil,
    toolNamePrefix: String? = nil,
    defaultApproval: ToolApprovalRequirement = .confirm
  ) {
    self.id = id
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
  }

  private enum CodingKeys: String, CodingKey {
    case id, enabled, displayName, url, headers, headerEnvironment, bearerToken
    case bearerTokenEnvironment
    case timeout, toolNamePrefix, defaultApproval
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      url: try container.decode(URL.self, forKey: .url),
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
        forKey: .defaultApproval) ?? .confirm)
  }

  public func resolved(environment: [String: String]) throws -> MCPServerConfiguration {
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

public struct MaiConfiguration: Codable, Equatable, Sendable {
  public var version: Int
  public var defaultAgent: String?
  public var providers: [ConfiguredProvider]
  public var mcpServers: [ConfiguredMCPServer]
  public var agents: [AgentDefinition]
  public var approvals: ConfiguredApprovals

  public init(
    version: Int = 1,
    defaultAgent: String? = nil,
    providers: [ConfiguredProvider] = [],
    mcpServers: [ConfiguredMCPServer] = [],
    agents: [AgentDefinition] = [],
    approvals: ConfiguredApprovals = .init()
  ) {
    self.version = version
    self.defaultAgent = defaultAgent
    self.providers = providers
    self.mcpServers = mcpServers
    self.agents = agents
    self.approvals = approvals
  }

  private enum CodingKeys: String, CodingKey {
    case version, defaultAgent, providers, mcpServers, agents, approvals
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
      defaultAgent: try container.decodeIfPresent(String.self, forKey: .defaultAgent),
      providers: try container.decodeIfPresent([ConfiguredProvider].self, forKey: .providers) ?? [],
      mcpServers: try container.decodeIfPresent([ConfiguredMCPServer].self, forKey: .mcpServers)
        ?? [],
      agents: try container.decodeIfPresent([AgentDefinition].self, forKey: .agents) ?? [],
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

  public func validate() throws {
    guard version == 1 else { throw MaiConfigurationError.unsupportedVersion(version) }
    try Self.requireUnique(providers.map(\.id), kind: "provider")
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
