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
  case textToSpeech
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
    case .textToSpeech: "Text to Speech"
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
    case .textToSpeech: "speaker.wave.2"
    case .files: "folder"
    case .memory: "brain"
    }
  }

}

enum NativeToolMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case context
  case onDemand

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .context: "Context"
    case .onDemand: "On-demand"
    }
  }

  var summary: String {
    switch self {
    case .context:
      return
        "Date & Time, Location, and Weather are rendered once and added to the system context. They re-render only when their parameters change."
    case .onDemand:
      return
        "Date & Time, Location, and Weather are exposed as callable tools the model invokes when needed."
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

enum ReasoningLevel: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case disabled
  case minimal
  case low
  case medium
  case high
  case xhigh

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .automatic: "Auto"
    case .disabled: "Off"
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    }
  }

  var systemImage: String {
    switch self {
    case .automatic: "brain"
    case .disabled: "xmark.circle"
    case .minimal: "tortoise"
    case .low: "speedometer"
    case .medium: "circle.lefthalf.filled"
    case .high: "flame"
    case .xhigh: "flame.fill"
    }
  }

  var reasoningEffortValue: String? {
    switch self {
    case .automatic: nil
    case .disabled: "none"
    case .minimal: "minimal"
    case .low: "low"
    case .medium: "medium"
    case .high, .xhigh: "high"
    }
  }
}

enum ContextWindowMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case full
  case last10
  case last5
  case lastMessage
  case none

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .full: "Full"
    case .last10: "Last 10 messages"
    case .last5: "Last 5 messages"
    case .lastMessage: "Last Message"
    case .none: "None"
    }
  }

  var messageLimit: Int? {
    switch self {
    case .full: nil
    case .last10: 10
    case .last5: 5
    case .lastMessage: 1
    case .none: 0
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
  var id: UUID = UUID()
  var role: ChatRole
  var text: String
  var createdAt: Date = Date()
}

struct ConversationSummary: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var title: String
  var createdAt: Date
  var updatedAt: Date
  var isIncognito: Bool
  var isPinned: Bool
  var isArchived: Bool
  var preview: String
  var hasMessages: Bool

  init(conversation: Conversation) {
    id = conversation.id
    title = conversation.title
    createdAt = conversation.createdAt
    updatedAt = conversation.updatedAt
    isIncognito = conversation.isIncognito
    isPinned = conversation.isPinned
    isArchived = conversation.isArchived
    hasMessages = !conversation.messages.isEmpty
    preview = conversation.messages.last.map {
      String($0.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    } ?? ""
  }

  var displayTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New chat" : title
  }

  var displayPreview: String {
    preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No messages" : preview
  }
}

struct Conversation: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var title: String = "New chat"
  var messages: [ChatMessage] = []
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var isIncognito: Bool = false
  var provider: ProviderKind = .apple
  var modelID: String = AppSettings.appleDefaultModelID
  var endpointID: UUID? = nil
  var systemPromptID: UUID? = nil
  var enabledTools: Set<NativeToolID> = AppSettings.defaultTools
  var usesStreaming: Bool = true
  var isPinned: Bool = false
  var disabledMCPTools: Set<String> = []
  var reasoningLevel: ReasoningLevel = .automatic
  var showThinking: Bool = false
  var lastToolContextSignature: String? = nil
  var isArchived: Bool = false

  init() {}

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
    case reasoningLevel
    case showThinking
    case lastToolContextSignature
    case isArchived
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
    reasoningLevel =
      (try? container.decode(ReasoningLevel.self, forKey: .reasoningLevel)) ?? .automatic
    showThinking = (try? container.decode(Bool.self, forKey: .showThinking)) ?? false
    lastToolContextSignature =
      try? container.decodeIfPresent(String.self, forKey: .lastToolContextSignature)
    isArchived = (try? container.decode(Bool.self, forKey: .isArchived)) ?? false
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
  var includeTimeZone: Bool = true
  var includeCurrentTime: Bool = true
  var includeYear: Bool = true
  var useGPSLocation: Bool = false
  var manualLocation: String = ""
  var weatherLocation: String = ""
  var webSearchProvider: WebSearchProvider = .duckDuckGo
  var todos: [TodoItem] = []
  var files: [ToolFile] = []
  var textToSpeechLanguage: String = ""
  var textToSpeechVoiceIdentifier: String = ""
  var textToSpeechRate: Double = 0.5
  var textToSpeechPitch: Double = 1.0

  static let defaults = NativeToolSettings()

  init() {}

  enum CodingKeys: String, CodingKey {
    case includeTimeZone, includeCurrentTime, includeYear, useGPSLocation
    case manualLocation, weatherLocation, webSearchProvider, todos, files
    case textToSpeechLanguage, textToSpeechVoiceIdentifier
    case textToSpeechRate, textToSpeechPitch
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = NativeToolSettings.defaults
    includeTimeZone =
      (try? c.decode(Bool.self, forKey: .includeTimeZone)) ?? defaults.includeTimeZone
    includeCurrentTime =
      (try? c.decode(Bool.self, forKey: .includeCurrentTime)) ?? defaults.includeCurrentTime
    includeYear = (try? c.decode(Bool.self, forKey: .includeYear)) ?? defaults.includeYear
    useGPSLocation = (try? c.decode(Bool.self, forKey: .useGPSLocation)) ?? defaults.useGPSLocation
    manualLocation =
      (try? c.decode(String.self, forKey: .manualLocation)) ?? defaults.manualLocation
    weatherLocation =
      (try? c.decode(String.self, forKey: .weatherLocation)) ?? defaults.weatherLocation
    webSearchProvider =
      (try? c.decode(WebSearchProvider.self, forKey: .webSearchProvider))
      ?? defaults.webSearchProvider
    todos = (try? c.decode([TodoItem].self, forKey: .todos)) ?? defaults.todos
    files = (try? c.decode([ToolFile].self, forKey: .files)) ?? defaults.files
    textToSpeechLanguage =
      (try? c.decode(String.self, forKey: .textToSpeechLanguage))
      ?? defaults.textToSpeechLanguage
    textToSpeechVoiceIdentifier =
      (try? c.decode(String.self, forKey: .textToSpeechVoiceIdentifier))
      ?? defaults.textToSpeechVoiceIdentifier
    textToSpeechRate =
      (try? c.decode(Double.self, forKey: .textToSpeechRate)) ?? defaults.textToSpeechRate
    textToSpeechPitch =
      (try? c.decode(Double.self, forKey: .textToSpeechPitch)) ?? defaults.textToSpeechPitch
  }
}

struct AppSettings: Codable, Equatable, Sendable {
  static let appleDefaultModelID = ""
  static let defaultTools: Set<NativeToolID> = []
  static let defaultSystemPrompt = SystemPrompt(
    name: "Helpful assistant",
    text:
      "You are a helpful, concise assistant for a private text-only chat app. Prefer clear answers and preserve useful formatting."
  )

  var defaultProvider: ProviderKind = .apple
  var appleModelID: String = AppSettings.appleDefaultModelID
  var selectedEndpointID: UUID? = nil
  var streamByDefault: Bool = true
  var showThinkingByDefault: Bool = false
  var openAIEndpoints: [OpenAIEndpoint] = []
  var systemPrompts: [SystemPrompt] = [AppSettings.defaultSystemPrompt]
  var defaultSystemPromptID: UUID = AppSettings.defaultSystemPrompt.id
  var defaultEnabledTools: Set<NativeToolID> = AppSettings.defaultTools
  var toolSettings: NativeToolSettings = .defaults
  var mcpServers: [MCPServer] = []
  var memory: String = ""
  var embedMemory: Bool = true
  var toolCallingMode: ToolCallingMode = .text
  var useToolProxy: Bool = false
  var contextWindowMode: ContextWindowMode = .full
  var nativeToolMode: NativeToolMode = .context

  static let defaults = AppSettings()

  init() {}

  func defaultPrompt() -> SystemPrompt {
    systemPrompts.first(where: { $0.id == defaultSystemPromptID }) ?? systemPrompts.first
      ?? AppSettings.defaultSystemPrompt
  }

  enum CodingKeys: String, CodingKey {
    case defaultProvider, appleModelID, selectedEndpointID, streamByDefault, showThinkingByDefault
    case openAIEndpoints, systemPrompts, defaultSystemPromptID, defaultEnabledTools
    case toolSettings, mcpServers, memory, embedMemory, toolCallingMode
    case useToolProxy, contextWindowMode, nativeToolMode
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    defaultProvider =
      (try? c.decode(ProviderKind.self, forKey: .defaultProvider)) ?? .apple
    appleModelID = (try? c.decode(String.self, forKey: .appleModelID)) ?? ""
    selectedEndpointID = try? c.decode(UUID.self, forKey: .selectedEndpointID)
    streamByDefault = (try? c.decode(Bool.self, forKey: .streamByDefault)) ?? true
    showThinkingByDefault = (try? c.decode(Bool.self, forKey: .showThinkingByDefault)) ?? false
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
    let storedMode = (try? c.decode(String.self, forKey: .toolCallingMode)) ?? "text"
    let migratedFromLegacyProxy = (storedMode == "proxy")
    toolCallingMode =
      ToolCallingMode(rawValue: storedMode) ?? .text
    useToolProxy =
      (try? c.decode(Bool.self, forKey: .useToolProxy)) ?? migratedFromLegacyProxy
    contextWindowMode =
      (try? c.decode(ContextWindowMode.self, forKey: .contextWindowMode)) ?? .full
    nativeToolMode =
      (try? c.decode(NativeToolMode.self, forKey: .nativeToolMode)) ?? .context
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
      preconditionFailure("AnyCodable cannot encode value of type \(type(of: value))")
    }
  }
}
