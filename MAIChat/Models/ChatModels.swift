import Foundation

enum ChatRole: String, Codable, CaseIterable, Identifiable, Sendable {
  case user
  case assistant
  case system
  case tool
  case error

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .user: "You"
    case .assistant: "Assistant"
    case .system: "System"
    case .tool: "Tool"
    case .error: "Error"
    }
  }
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case apple
  case openAICompatible

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .apple: "Apple"
    case .openAICompatible: "OpenAI-compatible"
    }
  }
}

enum ConversationExportFormat: String, CaseIterable, Identifiable, Sendable {
  case markdown
  case plainText
  case json

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .markdown: "Markdown"
    case .plainText: "Plain Text"
    case .json: "JSON"
    }
  }
}

enum NativeToolID: String, Codable, CaseIterable, Identifiable, Sendable {
  case datetime
  case location
  case weather
  case webSearch
  case todo
  case files
  case memory

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .datetime: "Date & Time"
    case .location: "Location"
    case .weather: "Weather"
    case .webSearch: "Web Search"
    case .todo: "Todo"
    case .files: "Files"
    case .memory: "Memory"
    }
  }

  var systemImage: String {
    switch self {
    case .datetime: "clock"
    case .location: "location"
    case .weather: "cloud.sun"
    case .webSearch: "magnifyingglass"
    case .todo: "checklist"
    case .files: "folder"
    case .memory: "brain"
    }
  }
}

enum ToolCallingMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case text
  case native

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .text: "Text protocol"
    case .native: "Native (OpenAI tools)"
    }
  }

  var summary: String {
    switch self {
    case .text:
      return
        "Works with any model. Tools are described in the system prompt; calls and results travel as <tool_call> / <tool_run> XML blocks."
    case .native:
      return
        "Adds OpenAI's structured tools array to each request so capable models can return tool_calls directly. Falls back to the text protocol on Apple Intelligence."
    }
  }
}

enum WebSearchProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case duckDuckGo
  case wikipedia
  case ollama
  case all

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .duckDuckGo: "DuckDuckGo"
    case .wikipedia: "Wikipedia"
    case .ollama: "Ollama Web Search"
    case .all: "All"
    }
  }
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var role: ChatRole
  var text: String
  var createdAt: Date

  init(id: UUID = UUID(), role: ChatRole, text: String, createdAt: Date = Date()) {
    self.id = id
    self.role = role
    self.text = text
    self.createdAt = createdAt
  }
}

struct Conversation: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var title: String
  var messages: [ChatMessage]
  var createdAt: Date
  var updatedAt: Date
  var isIncognito: Bool
  var provider: ProviderKind
  var modelID: String
  var endpointID: UUID?
  var systemPromptID: UUID?
  var enabledTools: Set<NativeToolID>
  var usesStreaming: Bool
  var isPinned: Bool
  var disabledMCPTools: Set<String>

  init(
    id: UUID = UUID(),
    title: String = "New chat",
    messages: [ChatMessage] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    isIncognito: Bool = false,
    provider: ProviderKind = .apple,
    modelID: String = AppSettings.appleDefaultModelID,
    endpointID: UUID? = nil,
    systemPromptID: UUID? = nil,
    enabledTools: Set<NativeToolID> = AppSettings.defaultTools,
    usesStreaming: Bool = true,
    isPinned: Bool = false,
    disabledMCPTools: Set<String> = []
  ) {
    self.id = id
    self.title = title
    self.messages = messages
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.isIncognito = isIncognito
    self.provider = provider
    self.modelID = modelID
    self.endpointID = endpointID
    self.systemPromptID = systemPromptID
    self.enabledTools = enabledTools
    self.usesStreaming = usesStreaming
    self.isPinned = isPinned
    self.disabledMCPTools = disabledMCPTools
  }

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case messages
    case createdAt
    case updatedAt
    case isIncognito
    case provider
    case modelID
    case endpointID
    case systemPromptID
    case enabledTools
    case usesStreaming
    case isPinned
    case disabledMCPTools
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    messages = try container.decode([ChatMessage].self, forKey: .messages)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    isIncognito = try container.decode(Bool.self, forKey: .isIncognito)
    provider = try container.decode(ProviderKind.self, forKey: .provider)
    modelID = try container.decode(String.self, forKey: .modelID)
    endpointID = try container.decodeIfPresent(UUID.self, forKey: .endpointID)
    systemPromptID = try container.decodeIfPresent(UUID.self, forKey: .systemPromptID)
    enabledTools = try container.decode(Set<NativeToolID>.self, forKey: .enabledTools)
    usesStreaming = try container.decode(Bool.self, forKey: .usesStreaming)
    isPinned = (try? container.decode(Bool.self, forKey: .isPinned)) ?? false
    disabledMCPTools =
      (try? container.decode(Set<String>.self, forKey: .disabledMCPTools)) ?? []
  }

  var displayTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New chat" : title
  }

  mutating func refreshTitle(from message: String) {
    guard title == "New chat" || title.isEmpty else { return }
    let compact = message.replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    title = String(compact.prefix(48))
    if title.isEmpty {
      title = "New chat"
    }
  }
}

struct OpenAIEndpoint: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var baseURL: String
  var apiKey: String
  var defaultModel: String
  var isEnabled: Bool

  init(
    id: UUID = UUID(),
    name: String = "New Endpoint",
    baseURL: String = "https://api.openai.com/v1",
    apiKey: String = "",
    defaultModel: String = "",
    isEnabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.defaultModel = defaultModel
    self.isEnabled = isEnabled
  }
}

struct SystemPrompt: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var text: String

  init(id: UUID = UUID(), name: String, text: String) {
    self.id = id
    self.name = name
    self.text = text
  }
}

struct TodoItem: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var title: String
  var isDone: Bool
  var createdAt: Date

  init(id: UUID = UUID(), title: String, isDone: Bool = false, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.isDone = isDone
    self.createdAt = createdAt
  }
}

struct ToolFile: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var excerpt: String
  var importedAt: Date

  init(id: UUID = UUID(), name: String, excerpt: String, importedAt: Date = Date()) {
    self.id = id
    self.name = name
    self.excerpt = excerpt
    self.importedAt = importedAt
  }
}

struct MCPToolDescriptor: Identifiable, Codable, Equatable, Sendable {
  var name: String
  var description: String
  var parametersJSON: String

  var id: String { name }

  init(name: String, description: String = "", parametersJSON: String = "") {
    self.name = name
    self.description = description
    self.parametersJSON = parametersJSON
  }

  enum CodingKeys: String, CodingKey {
    case name, description, parametersJSON
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    description = (try? c.decode(String.self, forKey: .description)) ?? ""
    parametersJSON = (try? c.decode(String.self, forKey: .parametersJSON)) ?? ""
  }
}

struct MCPServer: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var baseURL: String
  var isEnabled: Bool

  init(
    id: UUID = UUID(), name: String = "MCP Server", baseURL: String = "https://",
    isEnabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.isEnabled = isEnabled
  }

  var isHTTPS: Bool {
    URL(string: baseURL)?.scheme?.lowercased() == "https"
  }

  var hasValidScheme: Bool {
    let scheme = URL(string: baseURL)?.scheme?.lowercased() ?? ""
    return scheme == "https" || scheme == "http"
  }
}

struct NativeToolSettings: Codable, Equatable, Sendable {
  var includeTimeZone: Bool
  var includeCurrentTime: Bool
  var includeYear: Bool
  var useGPSLocation: Bool
  var manualLocation: String
  var weatherLocation: String
  var webSearchProvider: WebSearchProvider
  var todos: [TodoItem]
  var files: [ToolFile]

  static let defaults = NativeToolSettings(
    includeTimeZone: true,
    includeCurrentTime: true,
    includeYear: true,
    useGPSLocation: false,
    manualLocation: "",
    weatherLocation: "",
    webSearchProvider: .duckDuckGo,
    todos: [],
    files: []
  )
}

struct AppSettings: Codable, Equatable, Sendable {
  static let appleDefaultModelID = ""
  static let defaultTools: Set<NativeToolID> = [.datetime, .webSearch]

  var defaultProvider: ProviderKind
  var appleModelID: String
  var selectedEndpointID: UUID?
  var streamByDefault: Bool
  var openAIEndpoints: [OpenAIEndpoint]
  var systemPrompts: [SystemPrompt]
  var defaultSystemPromptID: UUID
  var defaultEnabledTools: Set<NativeToolID>
  var toolSettings: NativeToolSettings
  var mcpServers: [MCPServer]
  var memory: String
  var embedMemory: Bool
  var toolCallingMode: ToolCallingMode

  static let defaultSystemPrompt = SystemPrompt(
    name: "Helpful assistant",
    text:
      "You are a helpful, concise assistant for a private text-only chat app. Prefer clear answers and preserve useful formatting."
  )

  static var defaults: AppSettings {
    AppSettings(
      defaultProvider: .apple,
      appleModelID: appleDefaultModelID,
      selectedEndpointID: nil,
      streamByDefault: true,
      openAIEndpoints: [],
      systemPrompts: [defaultSystemPrompt],
      defaultSystemPromptID: defaultSystemPrompt.id,
      defaultEnabledTools: defaultTools,
      toolSettings: .defaults,
      mcpServers: [],
      memory: "",
      embedMemory: true,
      toolCallingMode: .text
    )
  }

  func defaultPrompt() -> SystemPrompt {
    systemPrompts.first(where: { $0.id == defaultSystemPromptID }) ?? systemPrompts.first
      ?? AppSettings.defaultSystemPrompt
  }

  init(
    defaultProvider: ProviderKind,
    appleModelID: String,
    selectedEndpointID: UUID?,
    streamByDefault: Bool,
    openAIEndpoints: [OpenAIEndpoint],
    systemPrompts: [SystemPrompt],
    defaultSystemPromptID: UUID,
    defaultEnabledTools: Set<NativeToolID>,
    toolSettings: NativeToolSettings,
    mcpServers: [MCPServer],
    memory: String,
    embedMemory: Bool,
    toolCallingMode: ToolCallingMode
  ) {
    self.defaultProvider = defaultProvider
    self.appleModelID = appleModelID
    self.selectedEndpointID = selectedEndpointID
    self.streamByDefault = streamByDefault
    self.openAIEndpoints = openAIEndpoints
    self.systemPrompts = systemPrompts
    self.defaultSystemPromptID = defaultSystemPromptID
    self.defaultEnabledTools = defaultEnabledTools
    self.toolSettings = toolSettings
    self.mcpServers = mcpServers
    self.memory = memory
    self.embedMemory = embedMemory
    self.toolCallingMode = toolCallingMode
  }

  enum CodingKeys: String, CodingKey {
    case defaultProvider, appleModelID, selectedEndpointID, streamByDefault
    case openAIEndpoints, systemPrompts, defaultSystemPromptID, defaultEnabledTools
    case toolSettings, mcpServers, memory, embedMemory, toolCallingMode
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    defaultProvider =
      (try? c.decode(ProviderKind.self, forKey: .defaultProvider)) ?? .apple
    appleModelID = (try? c.decode(String.self, forKey: .appleModelID)) ?? ""
    selectedEndpointID = try? c.decode(UUID.self, forKey: .selectedEndpointID)
    streamByDefault = (try? c.decode(Bool.self, forKey: .streamByDefault)) ?? true
    openAIEndpoints =
      (try? c.decode([OpenAIEndpoint].self, forKey: .openAIEndpoints)) ?? []
    systemPrompts =
      (try? c.decode([SystemPrompt].self, forKey: .systemPrompts))
      ?? [AppSettings.defaultSystemPrompt]
    defaultSystemPromptID =
      (try? c.decode(UUID.self, forKey: .defaultSystemPromptID))
      ?? (systemPrompts.first?.id ?? AppSettings.defaultSystemPrompt.id)
    defaultEnabledTools =
      (try? c.decode(Set<NativeToolID>.self, forKey: .defaultEnabledTools))
      ?? AppSettings.defaultTools
    toolSettings =
      (try? c.decode(NativeToolSettings.self, forKey: .toolSettings)) ?? .defaults
    mcpServers = (try? c.decode([MCPServer].self, forKey: .mcpServers)) ?? []
    memory = (try? c.decode(String.self, forKey: .memory)) ?? ""
    embedMemory = (try? c.decode(Bool.self, forKey: .embedMemory)) ?? true
    toolCallingMode =
      (try? c.decode(ToolCallingMode.self, forKey: .toolCallingMode)) ?? .text
  }
}

struct AnyCodable: Codable, Sendable {
  let value: any Sendable

  init(_ value: any Sendable) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      value = ""
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if let int = try? container.decode(Int.self) {
      value = int
    } else if let double = try? container.decode(Double.self) {
      value = double
    } else if let string = try? container.decode(String.self) {
      value = string
    } else if let array = try? container.decode([AnyCodable].self) {
      value = array
    } else if let dictionary = try? container.decode([String: AnyCodable].self) {
      value = dictionary
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case let bool as Bool:
      try container.encode(bool)
    case let int as Int:
      try container.encode(int)
    case let double as Double:
      try container.encode(double)
    case let string as String:
      try container.encode(string)
    case let array as [AnyCodable]:
      try container.encode(array)
    case let dictionary as [String: AnyCodable]:
      try container.encode(dictionary)
    default:
      try container.encode(String(describing: value))
    }
  }
}
